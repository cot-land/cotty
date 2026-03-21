#version 330 core

// Uniforms
uniform mat4 u_projection;
uniform vec2 u_cell_size;
uniform vec2 u_atlas_size;
uniform vec2 u_padding;

// Per-instance attributes (matches CellData struct: 20 bytes)
layout(location = 0) in uvec2 a_grid_pos;    // gridX, gridY
layout(location = 1) in uvec2 a_atlas_pos;   // atlasX, atlasY
layout(location = 2) in uvec2 a_glyph_size;  // glyphW, glyphH
layout(location = 3) in ivec2 a_offset;      // offX, offY
layout(location = 4) in vec4  a_color;       // r, g, b, a (normalized)

out vec2 v_tex_coord;
out vec4 v_color;

void main() {
    // Triangle strip: vertex 0-3 map to corners of the quad
    vec2 corner = vec2(gl_VertexID & 1, (gl_VertexID >> 1) & 1);

    vec2 origin = u_padding + u_cell_size * vec2(a_grid_pos);
    vec2 sz = vec2(a_glyph_size);
    vec2 off = vec2(a_offset);
    vec2 pos = origin + off + sz * corner;

    gl_Position = u_projection * vec4(pos, 0.0, 1.0);
    v_tex_coord = (vec2(a_atlas_pos) + sz * corner) / u_atlas_size;
    v_color = a_color;
}
