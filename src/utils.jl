# Splits a dictionary in two dicts, via a condition
function Base.split(condition::Function, associative::Associative)
    A = similar(associative)
    B = similar(associative)
    for (key, value) in associative
        if condition(key, value)
            A[key] = value
        else
            B[key] = value
        end
    end
    A, B
end


function assemble_shader(data)
    shader = data[:shader]
    delete!(data, :shader)
    default_bb = Signal(centered(AABB))
    bb  = get(data, :boundingbox, default_bb)
    if bb == nothing || isa(bb, Signal{Void})
        bb = default_bb
    end
    glp = get(data, :gl_primitive, GL_TRIANGLES)
    if haskey(data, :instances)
        robj = instanced_renderobject(data, shader, bb, glp, data[:instances])
    else
        robj = std_renderobject(data, shader, bb, glp)
    end
    for key in (:prerender, :postrender)
        if haskey(data, key)
            for elem in data[key]
                robj.(symbol("$(key)functions"))[elem[1]] = length(elem)<2 ? () : elem[2:end]
            end
        end
    end
    Context(robj)
end




function y_partition(area, percent)
    amount = percent / 100.0
    p = const_lift(area) do r
        (SimpleRectangle{Int}(r.x, r.y, r.w, round(Int, r.h*amount)),
            SimpleRectangle{Int}(r.x, round(Int, r.h*amount), r.w, round(Int, r.h*(1-amount))))
    end
    return const_lift(first, p), const_lift(last, p)
end
function x_partition(area, percent)
    amount = percent / 100.0
    p = const_lift(area) do r
        (SimpleRectangle{Int}(r.x, r.y, round(Int, r.w*amount), r.h ),
            SimpleRectangle{Int}(round(Int, r.w*amount), r.y, round(Int, r.w*(1-amount)), r.h))
    end
    return const_lift(first, p), const_lift(last, p)
end


glboundingbox(mini, maxi) = AABB{Float32}(Vec3f0(mini), Vec3f0(maxi)-Vec3f0(mini))
function default_boundingbox(main, model)
    main == nothing && return Signal(AABB{Float32}(Vec3f0(0), Vec3f0(1)))
    const_lift(*, model, AABB{Float32}(main))
end
call(::Type{AABB}, a::GPUArray) = AABB{Float32}(gpu_data(a))
call{T}(::Type{AABB{T}}, a::GPUArray) = AABB{T}(gpu_data(a))


"""
Returns two signals, one boolean signal if clicked over `robj` and another
one that consists of the object clicked on and another argument indicating that it's the first click
"""
function clicked(robj::RenderObject, button::MouseButton, window::Screen)
    @materialize mouse_hover, mouse_buttons_pressed = window.inputs
    leftclicked = const_lift(mouse_hover, mouse_buttons_pressed) do mh, mbp
        mh[1] == robj.id && mbp == Int[button]
    end
    clicked_on_obj = keepwhen(leftclicked, false, leftclicked)
    clicked_on_obj = const_lift((mh, x)->(x,robj,mh), mouse_hover, leftclicked)
    leftclicked, clicked_on_obj
end

is_same_id(id, robj) = id.id == robj.id
"""
Returns a boolean signal indicating if the mouse hovers over `robj`
"""
is_hovering(robj::RenderObject, window::Screen) =
    droprepeats(const_lift(is_same_id, mouse2id(window), robj))

function dragon_tmp(past, mh, mbp, mpos, robj, button, start_value)
    diff, dragstart_index, was_clicked, dragstart_pos = past
    over_obj = mh[1] == robj.id
    is_clicked = mbp == Int[button]
    if is_clicked && was_clicked # is draggin'
        return (dragstart_pos-mpos, dragstart_index, true, dragstart_pos)
    elseif over_obj && is_clicked && !was_clicked # drag started
        return (Vec2f0(0), mh[2], true, mpos)
    end
    return start_value
end

"""
Returns a signal with the difference from dragstart and current mouse position,
and the index from the current ROBJ id.
"""
function dragged_on(robj::RenderObject, button::MouseButton, window::Screen)
    @materialize mouse_buttons_pressed, mouseposition = window.inputs
    mousehover = mouse2id(window)
    mousedown = const_lift(GLAbstraction.singlepressed, mouse_buttons_pressed, GLFW.MOUSE_BUTTON_LEFT)
    condition = const_lift(is_same_id, mousehover, robj)
    dragg = GLAbstraction.dragged(mouseposition, mousedown, condition)
    filterwhen(mousedown, (value(dragg), 0), map(dragg) do d
        d, value(mousehover).index
    end)
end

points2f0{T}(positions::Vector{T}, range::Range) = Point2f0[Point2f0(range[i], positions[i]) for i=1:length(range)]

extrema2f0{T<:Intensity,N}(x::Array{T,N}) = Vec2f0(extrema(reinterpret(Float32,x)))
extrema2f0{T,N}(x::Array{T,N}) = Vec2f0(extrema(x))
extrema2f0(x::GPUArray) = extrema2f0(gpu_data(x))
function extrema2f0{T<:Vec,N}(x::Array{T,N})
    _norm = map(norm, x)
    Vec2f0(minimum(_norm), maximum(_norm))
end
