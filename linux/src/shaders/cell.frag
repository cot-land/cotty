#version 330 core

uniform sampler2D u_atlas;

in vec2 v_tex_coord;
in vec4 v_color;

out vec4 frag_color;

void main() {
    float a = texture(u_atlas, v_tex_coord).r;
    // Premultiplied alpha output (matches Metal shader)
    frag_color = vec4(v_color.rgb * a, v_color.a * a);
}
