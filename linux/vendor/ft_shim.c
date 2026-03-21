// Thin C shim for FreeType struct field access.
// Cot can't import C structs, so we expose getters.
// Same pattern as libcotty/vendor/treesitter_shim.c

#include <stdint.h>
#include <ft2build.h>
#include FT_FREETYPE_H

int64_t cotty_ft_metrics_ascender(FT_Face face) {
    return (int64_t)(face->size->metrics.ascender >> 6);
}

int64_t cotty_ft_metrics_descender(FT_Face face) {
    return (int64_t)(-(face->size->metrics.descender >> 6));
}

int64_t cotty_ft_metrics_height(FT_Face face) {
    return (int64_t)(face->size->metrics.height >> 6);
}

int64_t cotty_ft_glyph_advance_x(FT_Face face) {
    return (int64_t)(face->glyph->advance.x >> 6);
}

int64_t cotty_ft_glyph_bitmap_rows(FT_Face face) {
    return (int64_t)face->glyph->bitmap.rows;
}

int64_t cotty_ft_glyph_bitmap_width(FT_Face face) {
    return (int64_t)face->glyph->bitmap.width;
}

int64_t cotty_ft_glyph_bitmap_pitch(FT_Face face) {
    return (int64_t)face->glyph->bitmap.pitch;
}

int64_t cotty_ft_glyph_bitmap_buffer(FT_Face face) {
    return (int64_t)(intptr_t)face->glyph->bitmap.buffer;
}

int64_t cotty_ft_glyph_bitmap_left(FT_Face face) {
    return (int64_t)face->glyph->bitmap_left;
}

int64_t cotty_ft_glyph_bitmap_top(FT_Face face) {
    return (int64_t)face->glyph->bitmap_top;
}
