using Rebugger, Test

include("edit.jl")
include("interpret.jl")
if Sys.isunix()
    include("interpret_ui.jl")
else
    @warn "Skipping UI tests"
end
println("done")  # there is so much terminal manipulation, best to let the user know
