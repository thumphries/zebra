#include "zebra_append.h"
#include "zebra_clone.h"
#include "zebra_grow.h"

#include <stdio.h>

//
// Append: push a single value onto the end of an attribute.
// Take the value of attribute "in" at index "ix", and add it to the end of "out_into".
//
error_t zebra_append_attribute (anemone_mempool_t *pool, const zebra_attribute_t *in, int64_t ix, zebra_attribute_t *out_into)
{
    error_t err;

    int64_t out_ix = out_into->table.row_count;

    out_into->table.row_count++;
    // XXX: this will call grow_table twice (here and in append_table), but that should be ok
    err = zebra_grow_attribute (pool, out_into);
    if (err) return err;
    // XXX: cheating. so append_table works
    out_into->table.row_count--;

    err = zebra_append_table (pool, &in->table, ix, &out_into->table, 1);
    if (err) return err;

    out_into->times[out_ix] = in->times[ix];
    out_into->priorities[out_ix] = in->priorities[ix];
    out_into->tombstones[out_ix] = in->tombstones[ix];

    return 0;
}


error_t zebra_append_column (anemone_mempool_t *pool, const zebra_column_t *in, int64_t in_ix, zebra_column_t *out_into, int64_t out_ix, int64_t out_count)
{
    if (in->type != out_into->type) return ZEBRA_MERGE_DIFFERENT_COLUMN_TYPES;
    if (out_count == 0) return ZEBRA_SUCCESS;

    switch (in->type) {
        case ZEBRA_BYTE:
            for (int64_t ix = 0; ix != out_count; ++ix) {
                out_into->data.b[out_ix + ix] = in->data.b[in_ix + ix];
            }
            return ZEBRA_SUCCESS;

        case ZEBRA_INT:
            for (int64_t ix = 0; ix != out_count; ++ix) {
                out_into->data.i[out_ix + ix] = in->data.i[in_ix + ix];
            }
            return ZEBRA_SUCCESS;

        case ZEBRA_DOUBLE:
            for (int64_t ix = 0; ix != out_count; ++ix) {
                out_into->data.d[out_ix + ix] = in->data.d[in_ix + ix];
            }
            return ZEBRA_SUCCESS;

        case ZEBRA_ARRAY:
            {
                // find value start indices
                int64_t value_in_ix = 0;
                if (in_ix > 0) {
                    value_in_ix = in->data.a.s[in_ix-1] - in->data.a.s_offset;
                }
                int64_t nested_count = 0;
                int64_t s = 0;
                if (out_ix > 0) {
                    s = out_into->data.a.s[out_ix-1];
                } else {
                    s = out_into->data.a.s_offset;
                }

                for (int64_t ix = 0; ix != out_count; ++ix) {
                    int64_t n = in->data.a.n[in_ix + ix];
                    out_into->data.a.n[out_ix + ix] = n;
                    nested_count += n;
                    out_into->data.a.s[out_ix + ix] = s + nested_count;
                }

                return zebra_append_table (pool, &in->data.a.table, value_in_ix, &out_into->data.a.table, nested_count);
            }

        default:
            return ZEBRA_INVALID_COLUMN_TYPE;
    }
}

error_t zebra_append_table (anemone_mempool_t *pool, const zebra_table_t *in, int64_t in_ix, zebra_table_t *out_into, int64_t count)
{
    error_t err;

    int64_t out_ix = out_into->row_count;
    out_into->row_count += count;
    err = zebra_grow_table (pool, out_into);
    if (err) return err;

    for (int64_t c = 0; c < in->column_count; ++c) {
        err = zebra_append_column (pool, in->columns + c, in_ix, out_into->columns + c, out_ix, count);
        if (err) return err;
    }

    return ZEBRA_SUCCESS;
}

ANEMONE_STATIC
error_t zebra_fill_block_entity (anemone_mempool_t *pool, zebra_entity_t *entity, zebra_block_entity_t *block_entity)
{
    block_entity->hash = entity->hash;
    block_entity->id_length = entity->id_length;
    block_entity->id_bytes = ZEBRA_CLONE_ARRAY (pool, entity->id_bytes, entity->id_length);

    int64_t nonzeros = 0;
    for (int64_t c = 0; c != entity->attribute_count; ++c) {
        if (entity->attributes[c].table.row_count > 0)
            nonzeros++;
    }

    block_entity->attribute_count = nonzeros;
    block_entity->attribute_ids = anemone_mempool_alloc (pool, sizeof(int64_t) * nonzeros);
    block_entity->attribute_row_counts = anemone_mempool_alloc (pool, sizeof(int64_t) * nonzeros);

    int64_t sparse_ix = 0;
    for (int64_t c = 0; c != entity->attribute_count; ++c) {
        int64_t row_count = entity->attributes[c].table.row_count;
        if (row_count > 0) {
            block_entity->attribute_ids[sparse_ix] = c;
            block_entity->attribute_row_counts[sparse_ix] = row_count;
            sparse_ix++;
        }
    }

    return ZEBRA_SUCCESS;
}

error_t zebra_append_block_entity (anemone_mempool_t *pool, zebra_entity_t *entity, zebra_block_t **inout_block)
{
    error_t err;
    zebra_block_t *block = *inout_block;

    if (!block) {
        block = anemone_mempool_calloc (pool, 1, sizeof (zebra_block_t) );
    } else if (entity->attribute_count != block->table_count) {
        return ZEBRA_APPEND_DIFFERENT_ATTRIBUTE_COUNT;
    }

    block->entities = ZEBRA_GROW_ARRAY (pool, block->entities, block->entity_count, block->entity_count + 1);
    err = zebra_fill_block_entity (pool, entity, block->entities + block->entity_count);
    if (err) return err;
    block->entity_count++;

    int64_t old_row_count = block->row_count;
    int64_t new_row_count = block->row_count;
    for (int64_t c = 0; c != entity->attribute_count; ++c) {
        new_row_count += entity->attributes[c].table.row_count;
    }

    // TODO: this should check capacity and mutate if possible, otherwise grow and copy
    block->times = ZEBRA_GROW_ARRAY (pool, block->times, block->row_count, new_row_count);
    block->priorities = ZEBRA_GROW_ARRAY (pool, block->priorities, block->row_count, new_row_count);
    block->tombstones = ZEBRA_GROW_ARRAY (pool, block->tombstones, block->row_count, new_row_count);
    block->row_count = new_row_count;

    int64_t cur_row_count = old_row_count;
    for (int64_t c = 0; c != entity->attribute_count; ++c) {
        zebra_attribute_t *attribute = entity->attributes + c;
        int64_t row_count = attribute->table.row_count;

        memcpy (block->times + cur_row_count, attribute->times, row_count * sizeof(block->times[0]));
        memcpy (block->priorities + cur_row_count, attribute->priorities, row_count * sizeof(block->priorities[0]));
        memcpy (block->tombstones + cur_row_count, attribute->tombstones, row_count * sizeof(block->tombstones[0]));

        cur_row_count += row_count;
    }

    if (block->tables) {
        for (int64_t c = 0; c < block->table_count; ++c) {
            zebra_table_t *entity_table = &entity->attributes[c].table;
            zebra_table_t *block_table = block->tables + c;
            err = zebra_append_table (pool, entity_table, 0, block_table, entity_table->row_count);
            if (err) return err;
        }
    } else {
        block->table_count = entity->attribute_count;
        block->tables = anemone_mempool_calloc (pool, block->table_count, sizeof(zebra_table_t) );
        for (int64_t c = 0; c < block->table_count; ++c) {
            err = zebra_deep_clone_table (pool, &entity->attributes[c].table, block->tables + c);
            if (err) return err;
        }
    }

    *inout_block = block;
    return ZEBRA_SUCCESS;
}

