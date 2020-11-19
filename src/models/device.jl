function device!(
    x,
    output_ode,
    voltage_r,
    voltage_i,
    current_r,
    current_i,
    ix_range::UnitRange{Int64},
    ode_range::UnitRange{Int64},
    dynamic_device::DynG,
    inputs::SimulationInputs,
) where {DynG <: PSY.DynamicGenerator}
    sys = get_system(inputs)
    #Obtain local device states
    n_states = PSY.get_n_states(dynamic_device)
    device_states = @view x[ix_range]

    #Obtain references
    sys_Sbase = PSY.get_base_power(sys)
    sys_f0 = PSY.get_frequency(sys)
    sys_ω = get_ω_sys(inputs)
    #sys_ω = 1.0

    #Update Voltage data
    get_inner_vars(dynamic_device)[VR_gen_var] = voltage_r[1]
    get_inner_vars(dynamic_device)[VI_gen_var] = voltage_i[1]

    #Obtain ODEs and Mechanical Power for Turbine Governor
    mdl_tg_ode!(device_states, view(output_ode, ode_range), sys_ω, dynamic_device)

    #Obtain ODEs for AVR
    mdl_pss_ode!(device_states, view(output_ode, ode_range), sys_ω, dynamic_device)

    #Obtain ODEs for AVR
    mdl_avr_ode!(device_states, view(output_ode, ode_range), dynamic_device)

    #Obtain ODEs for Machine
    mdl_machine_ode!(
        device_states,
        view(output_ode, ode_range),
        current_r,
        current_i,
        sys_Sbase,
        sys_f0,
        dynamic_device,
    )

    #Obtain ODEs for PSY.Shaft
    mdl_shaft_ode!(
        device_states,
        view(output_ode, ode_range),
        sys_f0,
        sys_ω,
        dynamic_device,
    )

    get_inner_vars(dynamic_device) .= deepcopy(get_new_inner_vars(dynamic_device))
    return
end

function device!(
    voltage_r,
    voltage_i,
    current_r,
    current_i,
    device::PSY.Source,
    inputs::SimulationInputs,
)
    sys = get_system(inputs)
    mdl_source!(voltage_r, voltage_i, current_r, current_i, device, sys)
    return
end

function device!(
    voltage_r,
    voltage_i,
    current_r,
    current_i,
    device::PSY.PowerLoad,
    inputs::SimulationInputs,
)
    sys = get_system(inputs)
    mdl_Zload!(voltage_r, voltage_i, current_r, current_i, device, sys)
    return
end

function device!(
    x,
    output_ode::Vector{T},
    voltage_r,
    voltage_i,
    current_r,
    current_i,
    ix_range::UnitRange{Int64},
    ode_range::UnitRange{Int64},
    dynamic_device::DynI,
    inputs::SimulationInputs,
) where {DynI <: PSY.DynamicInverter, T <: Real}
    sys = get_system(inputs)
    #Obtain local device states
    n_states = PSY.get_n_states(dynamic_device)
    device_states = @view x[ix_range]

    #Obtain references
    Sbase = PSY.get_base_power(sys)
    sys_f0 = PSY.get_frequency(sys)
    sys_ω = get_ω_sys(inputs)

    #Update Voltage data
    get_inner_vars(dynamic_device)[VR_inv_var] = voltage_r[1]
    get_inner_vars(dynamic_device)[VI_inv_var] = voltage_i[1]

    #Update V_ref
    V_ref = PSY.get_ext(dynamic_device)[CONTROL_REFS][V_ref_index]
    get_inner_vars(dynamic_device)[V_oc_var] = V_ref

    #Obtain ODES for DC side
    mdl_DCside_ode!(dynamic_device)

    #Obtain ODEs for PLL
    mdl_freq_estimator_ode!(
        device_states,
        view(output_ode, ode_range),
        sys_f0,
        sys_ω,
        dynamic_device,
    )

    #Obtain ODEs for OuterLoop
    mdl_outer_ode!(
        device_states,
        view(output_ode, ode_range),
        sys_f0,
        sys_ω,
        dynamic_device,
    )

    #Obtain inner controller ODEs and modulation commands
    mdl_inner_ode!(device_states, view(output_ode, ode_range), dynamic_device)

    #Obtain converter relations
    mdl_converter_ode!(dynamic_device)

    #Obtain ODEs for output filter
    mdl_filter_ode!(
        device_states,
        view(output_ode, ode_range),
        current_r,
        current_i,
        Sbase,
        sys_f0,
        sys_ω,
        dynamic_device,
    )

    return
end
