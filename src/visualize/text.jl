visualize_default(::Union(GPUVector{GLSprite}, AbstractString), ::Style, kw_args=Dict()) = Dict(
    :primitive          => GLUVMesh2D(Rectangle(0f0, 0f0, 1f0, 1f0)),
    :styles             => Texture([RGBAU8(1.0,1.0,1.0,1.0)]),
    :atlas              => get_texture_atlas(),
    :technique          => :sprite,
    :preferred_camera   => :orthographic_pixel
)

function visualize_default(::Union(GPUVector{GLSprite}, AbstractString), ::Style{:square}, kw_args=Dict())
    return Dict(
        :primitive          => GLUVMesh2D(Rectangle(0f0, 0f0, 1f0, 1f0)),
        :styles             => Texture([RGBAU8(0,0,0,0), RGBAU8(0.7,.5,1.,0.5)]),
        :atlas              => get_texture_atlas(),
        :technique          => :square,
        :preferred_camera   => :orthographic_pixel,
    )
end

let TECHNIQUE_MAP = Dict(
        :sprite => Cint(1),
        :circle => Cint(2),
        :square => Cint(3),
    )
    global to_gl_technique
    to_gl_technique(technique) = TECHNIQUE_MAP[technique]
end


function visualize(text::AbstractString, s::Style, customizations=visualize_default(text, s))
    glyphs      = GPUVector(texture_buffer(process_for_gl(text)))
    positions   = GPUVector(texture_buffer(calc_position(glyphs)))
    style_index = GPUVector(texture_buffer(fill(GLSpriteStyle(0,0), length(text))))
    visualize(glyphs, positions, style_index, customizations[:model], s, customizations)  
end 

function visualize(
        glyphs      ::GPUVector{GLSprite}, 
        positions   ::GPUVector{Point2{Float16}},
        style_index ::GPUVector{GLSpriteStyle},
        model,
        s::Style, customizations=visualize_default(glyphs, s))

    @materialize! atlas, primitive, technique = customizations
    data = merge(customizations, Dict(
        :model               => model,
        :positions           => positions,
        :glyphs              => glyphs,
        :uvs                 => atlas.attributes,
        :images              => atlas.images,
        :style_index         => style_index,
        :technique           => lift(to_gl_technique, technique)
    ), collect_for_gl(primitive))

    shader = TemplateProgram(
        File(GLVisualize.shaderdir, "util.vert"), 
        File(GLVisualize.shaderdir, "text.vert"), 
        File(GLVisualize.shaderdir, "distance_shape.frag")
    )
    bb = AABB(gpu_data(positions))
    extent = FONT_EXTENDS[glyphs[1][1]]
    instanced_renderobject(data, glyphs, shader, Input(AABB{Float32}(bb.min, Vec3(bb.max)+Vec3(extent.advance..., 0f0))))
end


cursor_visible(range) = isempty(range) && first(range) > 0
cool_color(i)         = RGBA(sin(i), 1f0, 1f0, 1f0)
function cursor(positions, range, model)
    atlas = GLVisualize.get_texture_atlas()
    data = merge(Dict(
        :model               => model,
        :visible             => lift(cursor_visible, range),
        :offset              => lift(Cint, lift(first, range)),
        :color               => lift(cool_color, bounce(0f0:0.2f0:1f0)),
        :positions           => positions,
        :glyph               => Sprite{GLuint}(GLVisualize.get_font!('|')),
        :uvs                 => atlas.attributes.buffer,
        :images              => atlas.images,
        :preferred_camera    => :orthographic_pixel
    ), collect_for_gl(GLUVMesh2D(Rectangle(0f0, 0f0, 1f0, 1f0))))

    shader = TemplateProgram(
        File(GLVisualize.shaderdir, "util.vert"), 
        File(GLVisualize.shaderdir, "text_single.vert"), 
        File(GLVisualize.shaderdir, "text.frag")
    )
    std_renderobject(data, shader)
end
export cursor

function update_positions(glyphs, text, styles_index)
    oldpos      = text[:positions]
    positions   = GLVisualize.calc_position(glyphs)
    if length(oldpos) != length(positions)
        oldlength = length(oldpos)
        newlength = length(positions)
        resize!(oldpos, newlength)
        resize!(styles_index, newlength)
        resize!(text[:style_index], newlength)
        styles_index[1:newlength] = fill(GLSpriteStyle(0,0), newlength)
    end
    update!(oldpos, positions)
end

function textedit_signals(inputs, background, text)
    @materialize unicodeinput, selection, buttonspressed, arrow_navigation, mousedragdiff_objectid = inputs
    # create object which can globally hold the text and selection 
    text_raw    = TextWithSelection(text[:glyphs], 0:0)
    text_edit   = Input(text_raw)

    selection = lift(
        last, 
        foldl(
            move_cursor, 
            (selection.value, selection.value), 
            arrow_navigation, selection,
            text_edit
        )
    )

    is_text(x) = x[2][1] == background.id || x[2][1] == text.id
    selection  = keepwhen(
        lift(is_text, mousedragdiff_objectid), 
        0:0, selection
    )
    lift(s->(text_edit.value.selection=s), selection) # is there really no other way?!

    strg_v          = lift(==, buttonspressed, IntSet(GLFW.KEY_LEFT_CONTROL, GLFW.KEY_V))
    strg_c          = lift(==, buttonspressed, IntSet(GLFW.KEY_LEFT_CONTROL, GLFW.KEY_C))
    strg_x          = lift(==, buttonspressed, IntSet(GLFW.KEY_LEFT_CONTROL, GLFW.KEY_X))
    del             = lift(==, buttonspressed, IntSet(GLFW.KEY_BACKSPACE))

    clipboard_copy  = lift(copyclipboard,  keepwhen(strg_c, true, strg_v),  text_edit)

    delete_text     = lift(deletetext,     keepwhen(del,    true, del),     text_edit)
    cut_text        = lift(deletetext,     keepwhen(strg_x, true, strg_x),  text_edit)


    clipboard_paste = lift(clipboardpaste, keepwhen(strg_v, true, strg_v))

    text_gate       = lift(isnotempty, unicodeinput)
    unicode_input   = keepwhen(text_gate, Char['0'], unicodeinput)
    text_to_insert  = merge(clipboard_paste, unicode_input)
    text_to_insert  = lift(process_for_gl, text_to_insert)
    
    text_inserted   = lift(inserttext, text_edit, text_to_insert)

    text_updates    = merge(
        lift(return_nothing, text_inserted), 
        lift(return_nothing, clipboard_copy), 
        lift(return_nothing, delete_text), 
        lift(return_nothing, cut_text), 
        lift(return_nothing, selection)
    )
    text_selection_signal = sampleon(text_updates, text_edit)

    selection   = lift(x->x.selection,  text_selection_signal)
    text_sig    = lift(x->x.text,       text_selection_signal)

    lift(update_positions, text_sig, Input(text), Input(background[:style_index]))
    foldl(visualize_selection, 0:0, selection, Input(background[:style_index]))
    lift(utf8, text_sig), selection
end


function vizzedit(glyphs::GPUVector{GLSprite}, text::RenderObject, inputs)
    background = visualize(
        glyphs, 
        text[:positions], 
        GPUVector(texture_buffer(fill(GLSpriteStyle(0,0), length(text[:positions])))), 
        text[:model],
        Style{:square}()
    )
    text_sig, selection = textedit_signals(inputs, background, text)
    cursor_robj = cursor(text[:positions], selection, text[:model])

    (background, cursor_robj, text_sig)
end
export vizzedit