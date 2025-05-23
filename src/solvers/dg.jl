"""
    DG(; basis, surface_integral, volume_integral)

Create a discontinuous Galerkin method.
If `basis isa LegendreDerivativeOperator`, this creates a [`DGSEM`](@ref).
"""
struct DG{Basis, SurfaceIntegral, VolumeIntegral}
    basis::Basis
    surface_integral::SurfaceIntegral
    volume_integral::VolumeIntegral
end

function Base.show(io::IO, dg::DG)
    @nospecialize dg # reduce precompilation time

    print(io, "DG{", real(dg), "}(")
    print(io, dg.basis)
    print(io, ", ", dg.surface_integral)
    print(io, ", ", dg.volume_integral)
    print(io, ")")
end

function Base.show(io::IO, mime::MIME"text/plain", dg::DG)
    @nospecialize dg # reduce precompilation time

    if get(io, :compact, false)
        show(io, dg)
    else
        println(io, "DG{" * string(real(dg)) * "}")
        println(io, "    basis: ", dg.basis)
        println(io, "    surface integral: ", dg.surface_integral |> typeof |> nameof)
        print(io, "    volume integral: ", dg.volume_integral |> typeof |> nameof)
    end
end

Base.summary(io::IO, dg::DG) = print(io, "DG(" * summary(dg.basis) * ")")

@inline Base.real(dg::DG) = real(dg.basis)

grid(dg::DG) = grid(dg.basis)

"""
    eachnode(dg::DG)

Return an iterator over the indices that specify the location in relevant data structures
for the nodes in `dg`.
In particular, not the nodes themselves are returned.
"""
@inline eachnode(dg::DG) = Base.OneTo(nnodes(dg))
@inline nnodes(dg::DG) = length(grid(dg))
@inline function ndofs(mesh::Mesh, dg::DG)
    nelements(mesh) * nnodes(dg)^ndims(mesh)
end

@inline function get_node_coords(x, equations, solver::DG, indices...)
    return x[indices...]
end

# Adapted from Trixi.jl
# https://github.com/trixi-framework/Trixi.jl/blob/75d8c67629562efd24b2a04e46d22b0a1f4f572c/src/solvers/dg.jl#L539
@inline function get_node_vars(u, equations, indices...)
    # There is a cut-off at `n == 10` inside of the method
    # `ntuple(f::F, n::Integer) where F` in Base at ntuple.jl:17
    # in Julia `v1.5`, leading to type instabilities if
    # more than ten variables are used. That's why we use
    # `Val(...)` below.
    # We use `@inline` to make sure that the `getindex` calls are
    # really inlined, which might be the default choice of the Julia
    # compiler for standard `Array`s but not necessarily for more
    # advanced array types such as `PtrArray`s, cf.
    # https://github.com/JuliaSIMD/VectorizationBase.jl/issues/55
    SVector(ntuple(@inline(v->u[v, indices...]), Val(nvariables(equations))))
end

@inline function set_node_vars!(u, u_node, equations, indices...)
    for v in eachvariable(equations)
        u[v, indices...] = u_node[v]
    end
    return nothing
end

function allocate_coefficients(mesh::Mesh, equations, solver::DG, cache)
    return zeros(real(solver), nvariables(equations), nnodes(solver), nelements(mesh))
end

function compute_coefficients!(u, func, t, mesh::Mesh, equations, dg::DG, cache)
    for element in eachelement(mesh)
        for i in eachnode(dg)
            x_node = get_node_coords(cache.node_coordinates, equations, dg, i,
                                     element)
            u_node = func(x_node, t, equations)
            set_node_vars!(u, u_node, equations, i, element)
        end
    end
end

function reset_du!(du)
    du .= zero(du)
end

function rhs!(du, u, t, mesh::Mesh, equations, initial_condition,
              boundary_conditions, dg::DG, cache)
    @trixi_timeit timer() "reset ∂u/∂t" reset_du!(du)

    @trixi_timeit timer() "volume integral" begin
        calc_volume_integral!(du, u, mesh, equations,
                              dg.volume_integral, dg, cache)
    end

    @trixi_timeit timer() "interface flux" begin
        calc_interface_flux!(cache.surface_flux_values, u, mesh,
                             equations, dg.surface_integral, dg, cache)
    end

    @trixi_timeit timer() "boundary flux" begin
        calc_boundary_flux!(cache.surface_flux_values, u, t, boundary_conditions, mesh,
                            equations, dg.surface_integral, dg)
    end

    @trixi_timeit timer() "surface integral" begin
        calc_surface_integral!(du, u, mesh, equations,
                               dg.surface_integral, dg, cache)
    end

    @trixi_timeit timer() "Jacobian" apply_jacobian!(du, mesh, equations, dg, cache)

    return nothing
end
