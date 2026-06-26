const _DEFAULT_MOORING_ELASTIC_MODULUS_PA = 2.1e11
const _DEFAULT_MOORING_DENSITY_KG_PER_M3 = 7850.0
const _DEFAULT_MOORING_AREA_M2 = 0.01

Base.@kwdef struct MooringSystemModel{TPH,T<:Real}
    parameter_handler::TPH
    heave_stiffness_n_per_m::T
    damping_n_s_per_m::T
    constant_force_n::T
    mass_kg::T
end

_mooring_promoted_type(values...) = promote_type(map(typeof, values)...)

function _mooring_line_ids(ph)
    return sort!(collect(keys(ph.lines)))
end

function _mooring_segment_ids(ph, line_ids = _mooring_line_ids(ph))
    segment_ids = Set{Int}()
    for line_id in line_ids
        line = ph.lines[line_id]
        foreach(s_id -> push!(segment_ids, s_id), line.segments)
    end
    return sort!(collect(segment_ids))
end

function _mooring_axis(coords, requested_axis::Integer)
    axis = requested_axis == 0 ? length(coords) : requested_axis
    1 <= axis <= length(coords) || throw(ArgumentError("mooring axis $axis is outside coordinate dimension $(length(coords))"))
    return axis
end

function _mooring_material(ph, segment)
    if !haskey(ph.materials, segment.material_tag)
        throw(ArgumentError("mooring segment $(segment.id) references missing material tag $(segment.material_tag)"))
    end
    return ph.materials[segment.material_tag]
end

function _mooring_single_line_handler(ph, line_id::Integer)
    PH = Mooring.ParameterHandlers
    haskey(ph.lines, line_id) || throw(ArgumentError("mooring line $line_id is not present"))
    line = ph.lines[line_id]

    line_ph = PH.ParameterHandler()
    empty!(line_ph.points)
    empty!(line_ph.segments)
    empty!(line_ph.lines)
    line_ph.drags = copy(ph.drags)
    line_ph.waves = copy(ph.waves)
    line_ph.materials = copy(ph.materials)
    line_ph.motions = copy(ph.motions)
    line_ph.seabeds = copy(ph.seabeds)

    point_id_map = Dict{Int, Int}()
    remapped_points = Int[]
    for (new_point_id, old_point_id) in enumerate(line.points)
        point = ph.points[old_point_id]
        point_id_map[old_point_id] = new_point_id
        push!(remapped_points, new_point_id)
        line_ph.points[new_point_id] = PH.PointParameters(
            id = new_point_id,
            tag = point.tag,
            coords = point.coords,
            motion_tag = point.motion_tag,
            mesh_size = point.mesh_size,
        )
    end

    remapped_segments = Int[]
    for (new_segment_id, old_segment_id) in enumerate(line.segments)
        segment = ph.segments[old_segment_id]
        push!(remapped_segments, new_segment_id)
        line_ph.segments[new_segment_id] = PH.SegmentParameters(
            id = new_segment_id,
            tag = segment.tag,
            start_point = point_id_map[segment.start_point],
            stop_point = point_id_map[segment.stop_point],
            length = segment.length,
            density = segment.density,
            area = segment.area,
            material_tag = segment.material_tag,
            drag_tag = segment.drag_tag,
            seabed_tag = segment.seabed_tag,
        )
    end

    line_ph.lines[line_id] = PH.LineParameters(
        id = line_id,
        tag = line.tag,
        points = remapped_points,
        segments = remapped_segments,
    )
    return line_ph
end

"""
    mooring_parameter_handler(; kwargs...)

Build a `Mooring.ParameterHandlers.ParameterHandler` for a symmetric catenary
set using Mooring.jl's own point, segment, material, and line parameter types.
Coordinates use Mooring.jl's SI convention: horizontal axes first and vertical
position as the final coordinate, positive upward.
"""
function mooring_parameter_handler(;
    line_count::Integer = 3,
    water_depth_m::Real = 100.0,
    fairlead_depth_m::Real = 20.0,
    anchor_radius_m::Real = 120.0,
    line_length_m::Real = 160.0,
    segment_area_m2::Real = _DEFAULT_MOORING_AREA_M2,
    segment_density_kg_per_m3::Real = _DEFAULT_MOORING_DENSITY_KG_PER_M3,
    elastic_modulus_pa::Real = _DEFAULT_MOORING_ELASTIC_MODULUS_PA,
    mesh_size_m::Real = 10.0,
    material_tag::AbstractString = "mooring_material",
    motion_tag::AbstractString = "fixed",
    seabed_tag::AbstractString = "default_seabed",
)
    line_count >= 1 || throw(ArgumentError("line_count must be positive"))
    water_depth_m > fairlead_depth_m || throw(ArgumentError("water_depth_m must exceed fairlead_depth_m"))
    segment_area_m2 > 0 || throw(ArgumentError("segment_area_m2 must be positive"))
    segment_density_kg_per_m3 >= 0 || throw(ArgumentError("segment_density_kg_per_m3 must be nonnegative"))
    elastic_modulus_pa > 0 || throw(ArgumentError("elastic_modulus_pa must be positive"))
    line_length_m > 0 || throw(ArgumentError("line_length_m must be positive"))

    straight_length = hypot(anchor_radius_m, water_depth_m - fairlead_depth_m)
    if line_length_m < straight_length
        throw(ArgumentError("line_length_m must be at least the straight anchor-to-fairlead distance $(straight_length) m"))
    end

    PH = Mooring.ParameterHandlers
    ph = PH.ParameterHandler()
    empty!(ph.points)
    empty!(ph.segments)
    empty!(ph.lines)

    ph.materials[String(material_tag)] = PH.MaterialParameters(
        tag = String(material_tag),
        E = Float64(elastic_modulus_pa),
    )
    ph.motions[String(motion_tag)] = PH.MotionParameters(
        tag = String(motion_tag),
        type = "CustomMotion",
        f = "(t,x) -> VectorValue(0.0, 0.0, 0.0)",
    )
    ph.seabeds[String(seabed_tag)] = nothing

    for i in 1:line_count
        theta = 2 * pi * (i - 1) / line_count
        anchor_id = 2 * i - 1
        fairlead_id = 2 * i
        segment_id = i

        anchor = [
            Float64(anchor_radius_m * cos(theta)),
            Float64(anchor_radius_m * sin(theta)),
            -Float64(water_depth_m),
        ]
        fairlead = [0.0, 0.0, -Float64(fairlead_depth_m)]

        ph.points[anchor_id] = PH.PointParameters(
            id = anchor_id,
            tag = "Anchor_$i",
            coords = anchor,
            motion_tag = String(motion_tag),
            mesh_size = Float64(mesh_size_m),
        )
        ph.points[fairlead_id] = PH.PointParameters(
            id = fairlead_id,
            tag = "Fairlead_$i",
            coords = fairlead,
            motion_tag = String(motion_tag),
            mesh_size = Float64(mesh_size_m),
        )
        ph.segments[segment_id] = PH.SegmentParameters(
            id = segment_id,
            tag = "MooringSegment_$i",
            start_point = anchor_id,
            stop_point = fairlead_id,
            length = Float64(line_length_m),
            density = Float64(segment_density_kg_per_m3),
            area = Float64(segment_area_m2),
            material_tag = String(material_tag),
            drag_tag = "default_drag",
            seabed_tag = String(seabed_tag),
        )
        ph.lines[i] = PH.LineParameters(
            id = i,
            tag = "MooringLine_$i",
            points = [anchor_id, fairlead_id],
            segments = [segment_id],
        )
    end

    return ph
end

"""Return a dry-equivalent line mass in kg from Mooring.jl segment parameters."""
function mooring_mass_kg(ph; line_ids = _mooring_line_ids(ph))
    mass = 0.0
    for segment_id in _mooring_segment_ids(ph, line_ids)
        segment = ph.segments[segment_id]
        mass += segment.density * segment.area * segment.length
    end
    return mass
end

mooring_mass_kg(model::MooringSystemModel) = model.mass_kg
mooring_mass_kg(::Nothing) = 0.0

"""
    mooring_heave_stiffness_n_per_m(ph; axis = 0, line_ids = ...)

Estimate a scalar platform-DOF stiffness from Mooring.jl line, segment, and
material parameters. Each line is treated as axial segment stiffnesses in series
projected onto the selected coordinate axis. The default `axis = 0` selects the
last coordinate, matching Mooring.jl's vertical coordinate convention.
"""
function mooring_heave_stiffness_n_per_m(ph; axis::Integer = 0, line_ids = _mooring_line_ids(ph))
    stiffness = 0.0
    for line_id in line_ids
        line = ph.lines[line_id]
        isempty(line.points) && continue
        p_start = ph.points[first(line.points)].coords
        p_stop = ph.points[last(line.points)].coords
        dof_axis = _mooring_axis(p_start, axis)
        length(p_stop) == length(p_start) || throw(ArgumentError("line $line_id has inconsistent point dimensions"))

        delta = p_stop .- p_start
        straight_length = norm(delta)
        straight_length > 0 || continue
        projection = abs(delta[dof_axis]) / straight_length

        compliance = 0.0
        for segment_id in line.segments
            segment = ph.segments[segment_id]
            material = _mooring_material(ph, segment)
            segment.length > 0 || throw(ArgumentError("mooring segment $(segment.id) length must be positive"))
            segment.area > 0 || throw(ArgumentError("mooring segment $(segment.id) area must be positive"))
            material.E > 0 || throw(ArgumentError("mooring material $(segment.material_tag) E must be positive"))
            compliance += segment.length / (material.E * segment.area)
        end
        compliance > 0 || continue
        stiffness += projection^2 / compliance
    end
    return stiffness
end

"""
    mooring_system_model(ph; kwargs...)

Create a SIRENOpt platform adapter from a Mooring.jl parameter handler. The
stored stiffness is a lightweight linearized force model for time stepping; use
`mooring_quasistatic_solution` for the full package FE solve.
"""
function mooring_system_model(ph;
    heave_stiffness_n_per_m = nothing,
    damping_n_s_per_m::Real = 0.0,
    constant_force_n::Real = 0.0,
    mass_kg = nothing,
)
    stiffness = heave_stiffness_n_per_m === nothing ?
        mooring_heave_stiffness_n_per_m(ph) : heave_stiffness_n_per_m
    mass = mass_kg === nothing ? mooring_mass_kg(ph) : mass_kg
    T = _mooring_promoted_type(stiffness, damping_n_s_per_m, constant_force_n, mass)
    return MooringSystemModel(
        parameter_handler = ph,
        heave_stiffness_n_per_m = convert(T, stiffness),
        damping_n_s_per_m = convert(T, damping_n_s_per_m),
        constant_force_n = convert(T, constant_force_n),
        mass_kg = convert(T, mass),
    )
end

function mooring_system_model(;
    heave_stiffness_n_per_m = nothing,
    damping_n_s_per_m::Real = 0.0,
    constant_force_n::Real = 0.0,
    mass_kg = nothing,
    kwargs...,
)
    ph = mooring_parameter_handler(; kwargs...)
    return mooring_system_model(ph;
        heave_stiffness_n_per_m = heave_stiffness_n_per_m,
        damping_n_s_per_m = damping_n_s_per_m,
        constant_force_n = constant_force_n,
        mass_kg = mass_kg,
    )
end

function mooring_restoring_force(model::MooringSystemModel, position, velocity = zero(position))
    stiffness = model.heave_stiffness_n_per_m + zero(position)
    damping = model.damping_n_s_per_m + zero(position)
    constant = model.constant_force_n + zero(position)
    return constant - stiffness * position - damping * velocity
end

mooring_restoring_force(::Nothing, position, velocity = zero(position)) = zero(position)

"""Build Mooring.jl finite-element line objects from the stored parameter handler."""
function mooring_setup_lines(model::MooringSystemModel)
    lines = Dict{Int, Any}()
    for line_id in _mooring_line_ids(model.parameter_handler)
        line_ph = _mooring_single_line_handler(model.parameter_handler, line_id)
        merge!(lines, Mooring.MooringLines.setup_lines(line_ph))
    end
    return lines
end

"""Run Mooring.jl's nonlinear quasi-static finite-element solve explicitly."""
function mooring_quasistatic_solution(model::MooringSystemModel)
    displacements = Any[]
    references = Any[]
    for line_id in _mooring_line_ids(model.parameter_handler)
        line_ph = _mooring_single_line_handler(model.parameter_handler, line_id)
        u_line, x_line = Mooring.MooringLines.solve_quasistatic(line_ph)
        append!(displacements, u_line)
        append!(references, x_line)
    end
    return displacements, references
end
