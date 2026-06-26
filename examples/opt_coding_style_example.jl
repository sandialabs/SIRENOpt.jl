import Statistics: mean
import OWENSAero
import FLOWMath
using SNOW

ENV["GKSwstype"] = get(ENV, "GKSwstype", "100")
import Plots

Plots.default(
    size = (400, 300),
    linewidth = 1.5,
    markersize = 3,
    legend = false,
    foreground_color_legend = nothing,
    background_color_legend = nothing,
    left_margin = 6Plots.mm,
    bottom_margin = 6Plots.mm,
)

plot_cycle = ["#348ABD", "#A60628", "#009E73", "#7A68A6", "#D55E00", "#CC79A7"]

path, _ = splitdir(@__FILE__)
cp_plot = nothing

function objcon!(con, design_vars; runplot=false)
    AeroModel = "DMS"
    ntheta = 30
    R = 5.0 / 2 # m

    # Oval
    # Pairs where the mean radius of the ellipse is 1
    dtheta = 2 * pi / ntheta
    theta = collect(dtheta / 2:dtheta:2 * pi)
    a = R * 1.0
    b = R * 1.0
    shift = 11 # amount that the ellipse is rotated
    height = 1.5 # unitized slice height scaling
    chord = design_vars[1] # m
    RPM = 150.0

    delta = zeros(ntheta)
    omega = fill(RPM / 60.0 * 2 * pi, ntheta) # RPM -> radians/sec
    B = 3
    af = OWENSAero.readaerodyn(joinpath(path, "airfoils", "NACA_0015_RE3E5.dat")) # Use better airfoil data for real design work

    rho = 1.225
    mu = 1.7894e-5
    N_tsr = 5
    tsrvec = LinRange(0.1, 4.0, N_tsr)

    CPvec = similar(design_vars, N_tsr)

    for itsr in eachindex(tsrvec)
        Vinf = omega / tsrvec[itsr] * R

        # Apply the twist control points for the given TSR.
        twist_start = (itsr - 1) * 10 + 2
        twist_stop = itsr * 10 + 1
        twist_control_points = design_vars[twist_start:twist_stop] .* pi / 180
        dtheta = 2 * pi / length(twist_control_points)
        theta_control_points = collect(dtheta / 2:dtheta:2 * pi)
        twist = FLOWMath.akima(theta_control_points, twist_control_points, theta)

        # Radius as a function of azimuth angle and the input a and b widths
        r1 = a * b ./ sqrt.((b .* cos.(theta)) .^ 2 .+ (a .* sin.(theta)) .^ 2)
        # now rotate it discretely
        r = similar(r1)
        circshift!(r, r1, shift)

        x = -r .* sin.(theta)
        y = r .* cos.(theta)
        area = (maximum(y) - minimum(y)) * height # frontal area the wind sees

        env = OWENSAero.Environment(rho, mu, Vinf, "none", AeroModel, zeros(ntheta * 2))
        turbine = OWENSAero.Turbine(R, r .* R, chord, twist, delta, omega, B, af, ntheta, false)

        _, _, Q, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _ = OWENSAero.steady(turbine, env)

        CPvec[itsr] = mean(Q .* omega ./ (0.5 .* rho .* Vinf .^ 3.0 .* area))
    end

    if runplot
        global cp_plot
        if cp_plot === nothing
            cp_plot = Plots.plot(tsrvec, CPvec;
                color = plot_cycle[1],
                xlabel = "TSR",
                ylabel = "CP",
            )
        else
            Plots.plot!(cp_plot, tsrvec, CPvec; color = plot_cycle[2])
        end
        mkpath(joinpath(path, "figs"))
        Plots.savefig(cp_plot, joinpath(path, "figs", "CP_$shift.pdf"))
    end

    con[1] = 0 # -FLOWMath.ksmin(CPvec)  # 0 < power

    objective = -mean(CPvec)

    return objective
end


# Since we defined 5 TSRs above, and 10 control points for the pitch for each TSR, apply accordingly
x0 = zeros(10 * 5 + 1)
lx = zeros(10 * 5 + 1) .- 20.0
ux = zeros(10 * 5 + 1) .+ 20.0
x0[1] = 0.1524
lx[1] = 0.01
ux[1] = 2.0

N_constraints = 1
myIpoptoptions = Dict{String, Any}()
myIpoptoptions["hessian_approximation"] = "limited-memory"
myIpoptoptions["limited_memory_update_type"] = "bfgs"
myIpoptoptions["print_level"] = 5
myIpoptoptions["dual_inf_tol"] = 1e-1
myIpoptoptions["constr_viol_tol"] = 1e-1
myIpoptoptions["compl_inf_tol"] = 1e-1
myIpoptoptions["tol"] = 1e-4
myIpoptoptions["max_cpu_time"] = 200.0
optionsIPOPT = Options(solver=IPOPT(myIpoptoptions), derivatives=ForwardAD())
xopt, fopt, info, out = minimize(
    objcon!,
    x0,
    N_constraints,
    lx,
    ux,
    -Inf .* ones(N_constraints),
    0.0 .* ones(N_constraints),
    optionsIPOPT,
)

println(fopt)
x0 = zeros(10 * 5 + 1)
x0[1] = 0.1524
# Rerun with plotting
original_fopt = objcon!(zeros(N_constraints), x0; runplot=true)
objcon!(zeros(N_constraints), xopt; runplot=true)

println("Percent improvement in objective: $(-(original_fopt - fopt) / original_fopt * 100)")
