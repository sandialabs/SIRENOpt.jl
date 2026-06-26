using Profile
using SIRENOpt

"""
Profile hot SIRENOpt kernels without plotting, report writing, or solver mutation.

From the SIRENOpt.jl checkout:

    julia --project=. scripts/profile_hot_kernels.jl

Set `SIRENOPT_PROFILE_SAMPLES` to change the loop count. The default is small so
the script is safe to run interactively; it prints allocation and timing totals
for source, storage, process, and ontology constraint kernels.
"""
function profile_hot_kernels(; samples = parse(Int, get(ENV,
        "SIRENOPT_PROFILE_SAMPLES", "200")))
    scenario = ShortHorizonScenario(
        horizon_s = 3 * 60.0,
        dt_s = 60.0,
        solar_irradiance_kw_per_m2 = [0.1, 0.1, 0.1],
        wind_speed_m_s = [8.0, 8.0, 8.0],
        wave_power_flux_kw_per_m = [1.0, 1.0, 1.0],
        hydrokinetic_current_m_s = [2.0, 2.0, 2.0],
        load_kw = [1.5, 1.5, 1.5],
    )
    system = DynamicMultilevelHybridOntology(
        scenario = scenario,
        include_hydrokinetic = true,
        wind_rated_power_kw = 4.0,
        wave_rated_power_kw = 2.0,
        hydrokinetic_rated_power_kw = 3.0,
        hydrokinetic_rotor_diameter_m = 2.0,
        platform_inertia_kg_m2 = 1.0e5,
        platform_stiffness_nm_per_rad = 0.0,
        platform_damping_nm_s_per_rad = 0.0,
        wind_platform_moment_per_kw_nm = 500.0,
    )
    model = assemble(system, scenario, Collocation())
    x = copy(model.x0)

    solar = SolarDesign{Float64}()
    solar_op = SolarOp{Float64}(resource = TimeSeries([0.0], [0.6]))
    wind = WindDesign{Float64}(rated_power = 10.0)
    wind_op = WindOp{Float64}(resource = TimeSeries([0.0], [8.0]))
    battery = BatteryDesign{Float64}(capacity_kwh = 5.0)
    battery_op = BatteryOp{Float64}()
    h2 = H2Design{Float64}(electrolyzer_power_kw = 2.0)
    h2_op = H2Op{Float64}(demand = TimeSeries([0.0], [0.0]))

    elapsed = @elapsed begin
        Profile.clear()
        Profile.@profile for _ in 1:samples
            power_available_solar(solar, solar_op, 1)
            power_available_wind(wind, wind_op, 1)
            battery_step(battery, battery_op, 0.5, 1.0, 1.0)
            h2_step(h2, h2_op, 0.0, 1.0, 1.0, 1)
            evaluate_constraints(model, x)
        end
    end

    return (
        samples = samples,
        elapsed_s = elapsed,
        profile_samples = length(Profile.fetch()),
        variable_count = length(model.x0),
        constraint_count = length(model.constraint_lower_bounds),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = profile_hot_kernels()
    println("samples: ", result.samples)
    println("elapsed_s: ", result.elapsed_s)
    println("profile_samples: ", result.profile_samples)
    println("variable_count: ", result.variable_count)
    println("constraint_count: ", result.constraint_count)
end
