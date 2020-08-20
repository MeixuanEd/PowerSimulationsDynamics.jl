mutable struct Simulation
    reset::Bool
    problem::DiffEqBase.DAEProblem
    perturbations::Vector{<:Perturbation}
    x0_init::Vector{Float64}
    initialized::Bool
    tstops::Vector{Float64}
    callbacks::DiffEqBase.CallbackSet
    solution::Union{Nothing, DiffEqBase.DAESolution}
    simulation_folder::String
    simulation_inputs::SimulationInputs
end

"""
Initializes the simulations and builds the indexing. The initial conditions are stored in the system.

# Accepted Key Words
- `system_to_file::Bool`: Serializes the initialized system
"""
function Simulation!(
    simulation_folder::String,
    system::PSY.System,
    tspan::NTuple{2, Float64},
    perturbations::Vector{<:Perturbation} = Vector{Perturbation}();
    kwargs...,
)
    check_folder(simulation_folder)
    sim = build_simulation(simulation_folder, system, tspan, perturbations; kwargs...)
    if get(kwargs, :system_to_file, false)
        PSY.to_json(system, joinpath(simulation_folder, "initialized_system.json"))
    end
    return sim
end

"""
Initializes the simulations and builds the indexing. The input system is not modified during the initialization

# Accepted Key Words
- `system_to_file::Bool`: Serializes the original input system
"""
function Simulation(
    simulation_folder::String,
    system::PSY.System,
    tspan::NTuple{2, Float64},
    perturbations::Vector{<:Perturbation} = Vector{Perturbation}();
    kwargs...,
)
    check_folder(simulation_folder)
    simulation_system = deepcopy(system)
    if get(kwargs, :system_to_file, false)
        PSY.to_json(system, joinpath(simulation_folder, "input_system.json"))
    end
    return build_simulation(
        simulation_folder,
        simulation_system,
        tspan,
        perturbations;
        kwargs...,
    )
end

function build_simulation(
    simulation_folder::String,
    simulation_system::PSY.System,
    tspan::NTuple{2, Float64},
    perturbations::Vector{<:Perturbation} = Vector{Perturbation}();
    kwargs...,
)
    PSY.set_units_base_system!(simulation_system, "DEVICE_BASE")
    check_kwargs(kwargs, SIMULATION_ACCEPTED_KWARGS, "Simulation")
    initialized = false
    simulation_inputs = SimulationInputs(simulation_system)
    var_count = get_variable_count(simulation_inputs)

    flat_start = zeros(var_count)
    bus_count = length(PSY.get_components(PSY.Bus, simulation_system))
    flat_start[1:bus_count] .= 1.0
    x0_init = get(kwargs, :initial_guess, flat_start)

    initialize_simulation = get(kwargs, :initialize_simulation, true)
    if initialize_simulation
        @info("Initializing Simulation States")
        _add_aux_arrays!(simulation_inputs, Real)
        initialized = calculate_initial_conditions!(simulation_inputs, x0_init)
    end

    dx0 = zeros(var_count)
    callback_set, tstops = _build_perturbations(simulation_system, perturbations)
    _add_aux_arrays!(simulation_inputs, Float64)
    prob = DiffEqBase.DAEProblem(
        system!,
        dx0,
        x0_init,
        tspan,
        simulation_inputs,
        differential_vars = get_DAE_vector(simulation_inputs);
        kwargs...,
    )
    return Simulation(
        false,
        prob,
        perturbations,
        x0_init,
        initialized,
        tstops,
        callback_set,
        nothing,
        simulation_folder,
        simulation_inputs,
    )
end

function Simulation!(
    simulation_folder::String,
    system::PSY.System,
    tspan::NTuple{2, Float64},
    perturbation::Perturbation;
    initialize_simulation::Bool = true,
    kwargs...,
)
    return Simulation!(
        simulation_folder,
        system,
        tspan,
        [perturbation];
        initialize_simulation = initialize_simulation,
        kwargs...,
    )
end

function Simulation(
    simulation_folder::String,
    system::PSY.System,
    tspan::NTuple{2, Float64},
    perturbation::Perturbation;
    initialize_simulation::Bool = true,
    kwargs...,
)
    return Simulation(
        simulation_folder,
        system,
        tspan,
        [perturbation];
        initialize_simulation = initialize_simulation,
        kwargs...,
    )
end

function _add_aux_arrays!(inputs::SimulationInputs, ::Type{T}) where {T <: Number}
    bus_count = get_bus_count(inputs)
    get_aux_arrays(inputs)[1] = collect(zeros(T, bus_count))                       #I_injections_r
    get_aux_arrays(inputs)[2] = collect(zeros(T, bus_count))                       #I_injections_i
    get_aux_arrays(inputs)[3] = collect(zeros(T, get_n_injection_states(inputs)))  #injection_ode
    get_aux_arrays(inputs)[4] = collect(zeros(T, get_n_branches_states(inputs)))   #branches_ode
    get_aux_arrays(inputs)[5] = collect(zeros(Complex{T}, bus_count))              #I_bus
    get_aux_arrays(inputs)[6] = collect(zeros(T, 2 * bus_count))                   #I_balance
    return
end

function _build_perturbations(system::PSY.System, perturbations::Vector{<:Perturbation})
    isempty(perturbations) && return DiffEqBase.CallbackSet(), [0.0]
    perturbations_count = length(perturbations)
    callback_vector = Vector{DiffEqBase.DiscreteCallback}(undef, perturbations_count)
    tstops = Vector{Float64}(undef, perturbations_count)
    for (ix, pert) in enumerate(perturbations)
        condition = (x, t, integrator) -> t in [pert.time]
        affect = get_affect(system, pert)
        callback_vector[ix] = DiffEqBase.DiscreteCallback(condition, affect)
        tstops[ix] = pert.time
    end
    callback_set = DiffEqBase.CallbackSet((), tuple(callback_vector...))
    return callback_set, tstops
end

function _index_local_states!(
    component_state_index::Vector{Int64},
    local_states::Vector{Symbol},
    component::PSY.DynamicComponent,
)
    for (ix, s) in enumerate(PSY.get_states(component))
        component_state_index[ix] = findfirst(x -> x == s, local_states)
    end
    return
end

function _attach_ports!(component::PSY.DynamicComponent)
    PSY.get_ext(component)[PORTS] = Ports(component)
    return
end

function _attach_inner_vars!(
    device::PSY.DynamicGenerator,
    ::Type{T} = Real,
) where {T <: Real}
    device.ext[INNER_VARS] = zeros(T, 11)
    return
end

function _attach_inner_vars!(
    device::PSY.DynamicInverter,
    ::Type{T} = Real,
) where {T <: Real}
    device.ext[INNER_VARS] = zeros(T, 14)
    return
end

function _attach_control_refs!(device::PSY.DynamicInjection)
    device.ext[CONTROL_REFS] = [
        PSY.get_V_ref(device),
        PSY.get_ω_ref(device),
        PSY.get_P_ref(device),
        PSY.get_reactive_power(PSY.get_static_injector(device)),
    ]
    return
end

function _index_port_mapping!(
    index_component_inputs::Vector{Int64},
    local_states::Vector{Symbol},
    component::PSY.DynamicComponent,
)
    _attach_ports!(component)
    for i in PSY.get_ext(component)[PORTS].states
        tmp = [(ix, var) for (ix, var) in enumerate(local_states) if var == i]
        isempty(tmp) && continue
        push!(index_component_inputs, tmp[1][1])
    end

    return
end

function _get_Ybus(sys::PSY.System)
    n_buses = length(PSY.get_components(PSY.Bus, sys))
    dyn_lines = PSY.get_components(PSY.DynamicBranch, sys)
    if !isempty(PSY.get_components(PSY.ACBranch, sys))
        Ybus_ = PSY.Ybus(sys)
        Ybus = Ybus_[:, :]
        lookup = Ybus_.lookup[1]
        for br in dyn_lines
            ybus!(Ybus, br, lookup, -1.0)
        end
    else
        Ybus = SparseMatrixCSC{Complex{Float64}, Int64}(zeros(n_buses, n_buses))
        lookup = Dict{Int.Int}()
    end
    return Ybus, lookup
end

function _make_device_index!(device::PSY.DynamicInjection)
    states = PSY.get_states(device)
    device_state_mapping = Dict{Type{<:PSY.DynamicComponent}, Vector{Int64}}()
    input_port_mapping = Dict{Type{<:PSY.DynamicComponent}, Vector{Int64}}()
    _attach_inner_vars!(device)
    _attach_control_refs!(device)

    for c in PSY.get_dynamic_components(device)
        device_state_mapping[typeof(c)] = Vector{Int64}(undef, length(PSY.get_states(c)))
        input_port_mapping[typeof(c)] = Vector{Int64}()
        _index_local_states!(device_state_mapping[typeof(c)], states, c)
        _index_port_mapping!(input_port_mapping[typeof(c)], states, c)
        device.ext[LOCAL_STATE_MAPPING] = device_state_mapping
        device.ext[INPUT_PORT_MAPPING] = input_port_mapping
    end

    return
end

function _add_states_to_global!(
    global_state_index::MAPPING_DICT,
    state_space_ix::Vector{Int64},
    device::PSY.Device,
)
    global_state_index[PSY.get_name(device)] = Dict{Symbol, Int}()
    for s in PSY.get_states(device)
        state_space_ix[1] += 1
        global_state_index[PSY.get_name(device)][s] = state_space_ix[1]
    end

    return
end

function _get_internal_mapping(
    device::PSY.DynamicInjection,
    key::AbstractString,
    ty::Type{T},
) where {T <: PSY.DynamicComponent}
    device_index = PSY.get_ext(device)[key]
    val = get(device_index, ty, nothing)
    @assert !isnothing(val)
    return val
end

function get_local_state_ix(
    device::PSY.DynamicInjection,
    ty::Type{T},
) where {T <: PSY.DynamicComponent}
    return _get_internal_mapping(device, LOCAL_STATE_MAPPING, ty)
end

function get_input_port_ix(
    device::PSY.DynamicInjection,
    ty::Type{T},
) where {T <: PSY.DynamicComponent}
    return _get_internal_mapping(device, INPUT_PORT_MAPPING, ty)
end

function run_simulation!(sim::Simulation, solver; kwargs...)
    if sim.reset
        @error("Reset the simulation")
    end

    sim.solution = DiffEqBase.solve(
        sim.problem,
        solver;
        callback = sim.callbacks,
        tstops = sim.tstops,
        kwargs...,
    )
    return
end

function _change_vector_type(sys::PSY.System)
    for d in PSY.get_components(PSY.DynamicInjection, sys)
        _attach_inner_vars!(d, Real)
    end
end

function _determine_stability(vals::Vector{Complex{Float64}})
    stable = true
    for real_eig in real(vals)
        real_eig > 0.0 && return false
    end
    return true
end

function small_signal_analysis(sim::Simulation; kwargs...)
    if sim.reset
        @error("Reset the simulation")
    end
    system = get_system(sim.simulation_inputs)
    _change_vector_type(system)
    _add_aux_arrays!(sim.simulation_inputs, Real)
    var_count = get_variable_count(sim.simulation_inputs)
    dx0 = zeros(var_count) #Define a vector of zeros for the derivative
    bus_count = get_bus_count(sim.simulation_inputs)
    sysf! = (out, x) -> system!(
        out,            #output of the function
        dx0,            #derivatives equal to zero
        x,              #states
        sim.simulation_inputs,     #Parameters
        0.0,            #time equals to zero.
    )
    out = zeros(var_count) #Define a vector of zeros for the output
    x_eval = get(kwargs, :operating_point, sim.x0_init)
    jacobian = ForwardDiff.jacobian(sysf!, out, x_eval)
    diff_states = collect(trues(var_count))
    diff_states[1:(2 * bus_count)] .= false
    for b_ix in get_voltage_buses_ix(sim.simulation_inputs)
        diff_states[b_ix] = true
        diff_states[b_ix + bus_count] = true
    end
    alg_states = .!diff_states
    fx = @view jacobian[diff_states, diff_states]
    gy = jacobian[alg_states, alg_states]
    fy = @view jacobian[diff_states, alg_states]
    gx = @view jacobian[alg_states, diff_states]
    # TODO: Make operation using BLAS!
    reduced_jacobian = fx - fy * inv(gy) * gx
    vals, vect = LinearAlgebra.eigen(reduced_jacobian)
    sources = collect(PSY.get_components(PSY.Source, system))
    if isempty(sources)
        @warn("No Infinite Bus found. Confirm stability directly checking eigenvalues.\nIf all eigenvalues are on the left-half plane and only one eigenvalue is zero, the system is small signal stable.")
        info_evals = "Eigenvalues are:\n"
        for i in vals
            info_evals = info_evals * string(i) * "\n"
        end
        @info(info_evals)
    end
    return SmallSignalOutput(
        reduced_jacobian,
        vals,
        vect,
        _determine_stability(vals),
        x_eval,
    )
end
