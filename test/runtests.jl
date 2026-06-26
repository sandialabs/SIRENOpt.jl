using Test

@testset "SIRENOpt default tier" begin
    include("default_runtests.jl")
end

if get(ENV, "SIRENOPT_RUN_LONG_TESTS", "0") == "1"
    include("long_runtests.jl")
else
    @info "Skipping SIRENOpt long tests in default tier; set SIRENOPT_RUN_LONG_TESTS=1 to include them."
end
