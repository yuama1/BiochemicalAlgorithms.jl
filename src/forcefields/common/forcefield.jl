export 
    ForceField,
    AbstractForceFieldComponent,
    init_atom_types,
    assign_typenames_and_charges!,
    setup!,
    update!,
    compute_energy,
    compute_forces,
    count_warnings,
    print_warnings

const force_prefactor = ustrip(u"kJ/mol/angstrom"/Constants.N_A |> u"N")

abstract type AbstractForceFieldComponent{T<:Real} end

@auto_hash_equals struct ForceField{T<:Real} 
    name::String
    system::AbstractAtomContainer{T}
    parameters::AbstractForceFieldParameters
    options::Dict{Symbol, Any}
    atom_type_templates::Dict{String, AtomTypeTemplate{T}}
    components::Vector{AbstractForceFieldComponent{T}}
    energy::Dict{String, T}
    unassigned_atoms::Vector{Atom{T}}
    constrained_atoms::Vector{Int}
end

function init_atom_types(params::AbstractForceFieldParameters, T=Float32)
    tpl_section = extract_section(params, "ChargesAndTypeNames")

    unit_q  = get(tpl_section.properties, "unit_q", "e_au")

    # UnitfulAtomic uses e_au for e0
    if unit_q == "e0"
        unit_q = "e_au"
    end

    q_factor  = ustrip((1uparse(unit_q; unit_context=UnitfulAtomic))  |> u"e_au")

    Dict{String, AtomTypeTemplate{T}}(
        t.name => AtomTypeTemplate{T}(t.type, T(q_factor*t.q))
        for t in eachrow(tpl_section.data)
    )
end

function _try_assign!(
        templates::Dict{String, AtomTypeTemplate{T}}, 
        name::String, 
        atom::Atom{T};
        assign_typenames::Bool,
        overwrite_typenames::Bool,
        assign_charges::Bool,
        overwrite_charges::Bool) where {T<:Real}
    if haskey(templates, name)
        qbs = templates[name]

        if assign_typenames && (overwrite_typenames || strip(atom.atom_type) == "")
            atom.atom_type = qbs.type_name
        end

        if assign_charges && (overwrite_charges || atom.charge == zero(T))
            atom.charge = qbs.charge
        end
        
        return true
    else
        return false
    end
end

function assign_typenames_and_charges!(ff::ForceField{T}) where {T<:Real}
    assign_typenames = ff.options[:assign_typenames]
    assign_charges   = ff.options[:assign_charges]

    overwrite_typenames = ff.options[:overwrite_typenames]
    overwrite_charges   = ff.options[:overwrite_nonzero_charges]

    if !assign_charges && !assign_typenames
        # nothing to do...
        return
    end

    # clear the list of unassigned_atoms
    empty!(ff.unassigned_atoms)

    for atom in eachatom(ff.system)
        if !_try_assign!(
                ff.atom_type_templates, 
                get_full_name(atom), 
                atom;
                assign_typenames=assign_typenames,
                overwrite_typenames=overwrite_typenames,
                assign_charges=assign_charges,
                overwrite_charges=overwrite_charges
            )

            # we don't have a type for the full type name; let's try without
            # variant extension
            name = 
            if !_try_assign!(
                    ff.atom_type_templates, 
                    get_full_name(atom, FullNameType.NO_VARIANT_EXTENSIONS),
                    atom;
                    assign_typenames=assign_typenames,
                    overwrite_typenames=overwrite_typenames,
                    assign_charges=assign_charges,
                    overwrite_charges=overwrite_charges
                )
                # ok, one more try... let's try with a wildcard for the residue name
                name = "*:" * atom.name
                if !_try_assign!(
                        ff.atom_type_templates, 
                        "*:" * atom.name, 
                        atom;
                        assign_typenames=assign_typenames,
                        overwrite_typenames=overwrite_typenames,
                        assign_charges=assign_charges,
                        overwrite_charges=overwrite_charges
                    )
                    # ok, we really don't know the atom type
                    @warn "assign_typenames_and_charges!(): cannot assign charge for atom $(get_full_name(atom))"

                    push!(ff.unassigned_atoms, atom)
                    if length(ff.unassigned_atoms) > ff.options[:max_number_of_unassigned_atoms]
                        @warn "assigned_typenames_and_charges!(): Too many unassigned atoms"
                        throw(TooManyErrors())
                    end
                end
            end
        end
    end
end


function setup!(component::AbstractForceFieldComponent) end
function update!(component::AbstractForceFieldComponent) end
function count_warnings(component::AbstractForceFieldComponent) 0 end
function print_warnings(component::AbstractForceFieldComponent) end

function setup!(ff::ForceField{T}) where {T<:Real}
    map(setup!, ff.components)

    warning_counts = map(count_warnings, ff.components)

    if sum(warning_counts) > 0

        max_length = maximum(length(c.name) for (i,c) in enumerate(ff.components) if warning_counts[i] > 0)

        warning_string = "$(sum(warning_counts)) warnings occurred during setup that were suppressed:\n"
        warning_string *= "Components:\n"
        for (i, c) in enumerate(ff.components)
            if warning_counts[i] > 0
                warning_string *= Printf.format(
                    Printf.Format("%-$(max_length)s: %d warnings\n"),
                        c.name, 
                        warning_counts[i]
                )
            end
        end
        warning_string *= "Use print_warnings(ff) to display them."

        @warn warning_string
    end
end

"""
   Update the internal data structures of the force field when the system changes
   (e.g., through coordinate updates)

   Please note that changes to the options or the topology require a call to ```setup!````
   prior to the call to ```update!````.
"""
function update!(ff::ForceField{T}) where {T<:Real}
    map(update!, ff.components)
end

function compute_energy(ff::ForceField{T}; verbose=false)::T where {T<:Real}
    total_energy = mapreduce(compute_energy, +, ff.components; init=zero(T))

    for c in ff.components
        for (name, value) in c.energy
            ff.energy[name] = value
        end
    end

    if verbose
        @info "AMBER Energy:"

        max_length = maximum([length(k) for (k, _) in ff.energy])
        f_string = Printf.Format("%-$(max_length)s: %.9g kJ/mol")
        
        for (name, value) in ff.energy
            @info Printf.format(f_string, name, value)
        end

        @info repeat("-", max_length + 19)
        @info Printf.format(f_string, "total energy:", total_energy)
    end

    total_energy
end

function compute_forces(ff::ForceField{T}) where {T<:Real}
    # first, zero out the current forces
    atoms_df(ff.system).F .= Ref(zero(Vector3{T}))
    
    map(compute_forces, ff.components)

    nothing
end

function print_warnings(ff::ForceField{T}) where {T<:Real}
    for component in ff.components
        print_warnings(component)
    end
end

@inline Base.show(io::IO, ::MIME"text/plain", ff::ForceField) = println(io, 
    "$(ff.name) for $(natoms(ff.system)) atoms with $(nbonds(ff.system)) bonds.")
@inline Base.show(io::IO, ff::ForceField) = println(io, 
    "$(ff.name) for $(natoms(ff.system)) atoms with $(nbonds(ff.system)) bonds.")