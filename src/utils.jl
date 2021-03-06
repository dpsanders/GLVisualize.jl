function include_all(folder::String)
    for file in readdir(folder)
        if endswith(file, ".jl")
            include(joinpath(folder, file))
        end
    end
end

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

#creates methods to accept signals, which then gets transfert to an OpenGL target type
macro visualize_gen(input, target, S)
    esc(quote 
        visualize(value::$input, s::$S, customizations=visualize_default(value, s)) = 
            visualize($target(value), s, customizations)

        function visualize(signal::Signal{$input}, s::$S, customizations=visualize_default(signal.value, s))
            tex = $target(signal.value)
            lift(update!, Input(tex), signal)
            visualize(tex, s, customizations)
        end
    end)
end


# scalars can be uploaded directly to gpu, but not arrays
texture_or_scalar(x) = x
texture_or_scalar(x::Array) = Texture(x)
function texture_or_scalar{A <: Array}(x::Signal{A})
    tex = Texture(x.value)
    lift(update!, tex, x)
    tex
end

isnotempty(x) = !isempty(x)
AND(a,b) = a&&b

