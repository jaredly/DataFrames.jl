abstract AbstractDataFrame <: Associative{String, Any}

type DataFrame <: AbstractDataFrame
    columns::Vector{Any}
    colindex::Index

    function DataFrame(cols::Vector{Any}, colind::Index)
        ncols = length(cols)
        if ncols > 1
            nrows = length(cols[1])
            equallengths = true
            for i in 2:ncols
                equallengths &= length(cols[i]) == nrows
            end
            if !equallengths
                msg = "All columns in a DataFrame must be the same length"
                throw(ArgumentError(msg))
            end
        end
        if length(colind) != ncols
            msg = "Columns and column index must be the same length"
            throw(ArgumentError(msg))
        end
        new(cols, colind)
    end
end

# A DataFrame from keyword arguments
# This also covers the empty DataFrame.
function DataFrame(;kwargs...)
    result = DataFrame({}, Index())
    for (k,v) in kwargs
        result[string(k)] = v
    end
    return result
end

# No-op given a DataFrame
DataFrame(df::DataFrame) = df

# Wrap a scalar in a DataArray, then a DataFrame
function DataFrame(x::Union(Number, String))
    cols = {DataArray([x], falses(1))}
    colind = Index(gennames(1))
    return DataFrame(cols, colind)
end

# Wrap a set of columns in a DataFrame w/ or w/o column names
function DataFrame{T <: String}(cs::Vector{Any},
                                cn::Vector{T} = gennames(length(cs)))
    return DataFrame(cs, Index(cn))
end

# Build a DataFrame from an expression
# TODO: Expand the following to allow unequal lengths that are rep'd
#       to the longest length.
DataFrame(ex::Expr) = based_on(DataFrame(), ex)

# Convert a standard Matrix to a DataFrame w/ pre-specified names
function DataFrame(x::Matrix,
                   cn::Vector = gennames(size(x, 2)))
    n = length(cn)
    cols = Array(Any, n)
    for i in 1:n
        cols[i] = DataArray(x[:, i])
    end
    return DataFrame(cols, Index(cn))
end

function DataFrame{K, V}(d::Associative{K, V})
    # Find the first position with maximum length in the Dict.
    lengths = map(length, values(d))
    max_length = maximum(lengths)
    maxpos = findfirst(lengths .== max_length)
    keymaxlen = keys(d)[maxpos]
    nrows = max_length
    # Start with a blank DataFrame
    df = DataFrame() 
    for (k, v) in d
        if length(v) == nrows
            df[k] = v  
        elseif rem(nrows, length(v)) == 0    # nrows is a multiple of length(v)
            df[k] = vcat(fill(v, div(nrows, length(v)))...)
        else
            vec = fill(v[1], nrows)
            j = 1
            for i = 1:nrows
                vec[i] = v[j]
                j += 1
                if j > length(v)
                    j = 1
                end
            end
            df[k] = vec
        end
    end
    df
end

# Construct a DataFrame with groupings over the columns
# TODO: Restore grouping
function DataFrame(cs::Vector,
                   cn::Vector,
                   gr::Dict{ByteString, Vector{ByteString}})
    d = DataFrame(cs, cn)
    set_groups(index(d), gr)
    return d
end

# Pandas' Dict of Vectors -> DataFrame constructor w/ explicit column names
function DataFrame(d::Dict)
    column_names = sort(convert(Array{ByteString, 1}, collect(keys(d))))
    p = length(column_names)
    if p == 0
        DataFrame()
    end
    n = length(d[column_names[1]])
    columns = Array(Any, p)
    for j in 1:p
        if length(d[column_names[j]]) != n
            throw(ArgumentError("All columns must have the same length"))
        end
        columns[j] = DataArray(d[column_names[j]])
    end
    return DataFrame(columns, Index(column_names))
end

# Pandas' Dict of Vectors -> DataFrame constructor w/o explicit column names
function DataFrame(d::Dict, column_names::Vector)
    p = length(column_names)
    if p == 0
        DataFrame()
    end
    n = length(d[column_names[1]])
    columns = Array(Any, p)
    for j in 1:p
        if length(d[column_names[j]]) != n
            error("All inputs must have the same length")
        end
        columns[j] = DataArray(d[column_names[j]])
    end
    return DataFrame(columns, Index(column_names))
end

# Initialize empty DataFrame objects of arbitrary size
# t is a Type
function DataFrame(t::Any, nrows::Integer, ncols::Integer)
    columns = Array(Any, ncols)
    for i in 1:ncols
        columns[i] = DataArray(t, nrows)
    end
    column_names = gennames(ncols)
    return DataFrame(columns, Index(column_names))
end

# Initialize empty DataFrame objects of arbitrary size
# Use the default column type
function DataFrame(nrows::Integer, ncols::Integer)
    columns = Array(Any, ncols)
    for i in 1:ncols
        columns[i] = DataArray(DEFAULT_COLUMN_TYPE, nrows)
    end
    column_names = gennames(ncols)
    return DataFrame(columns, Index(column_names))
end

# Initialize an empty DataFrame with specific types and names
function DataFrame(column_types::Vector, column_names::Vector, nrows::Integer)
    p = length(column_types)
    columns = Array(Any, p)
    for j in 1:p
        columns[j] = DataArray(column_types[j], nrows)
        for i in 1:nrows
            # TODO: Find a way to get rid of this line
            # Problem may be in show()
            columns[j][i] = baseval(column_types[j])
            columns[j][i] = NA
        end
    end
    return DataFrame(columns, Index(column_names))
end

# Initialize an empty DataFrame with specific types
function DataFrame(column_types::Vector, nrows::Integer)
    p = length(column_types)
    columns = Array(Any, p)
    column_names = gennames(p)
    for j in 1:p
        columns[j] = DataArray(column_types[j], nrows)
        for i in 1:nrows
            # TODO: Find a way to get rid of this line
            # Problem may be in show()
            columns[j][i] = baseval(column_types[j])
            columns[j][i] = NA
        end
    end
    return DataFrame(columns, Index(column_names))
end

# Initialize from a Vector of Associatives (aka list of dicts)
function DataFrame{D <: Associative}(ds::Vector{D})
    ks = [Set([[k for k in [collect(keys(d)) for d in ds]]...]...)...]
    DataFrame(ds, ks)
end

# Initialize from a Vector of Associatives (aka list of dicts)
function DataFrame{D <: Associative, T <: String}(ds::Vector{D}, ks::Vector{T})
    invoke(DataFrame, (Vector{D}, Vector), ds, ks)
end

function DataFrame{D <: Associative}(ds::Vector{D}, ks::Vector)
    #get column types
    col_types = Any[None for i = 1:length(ks)]
    for d in ds
        for (i,k) in enumerate(ks)
            # TODO: check for user-defined "NA" values, ala pandas
            if haskey(d, k) && !isna(d[k])
                try
                    col_types[i] = promote_type(col_types[i], typeof(d[k]))
                catch
                    col_types[i] = Any
                end
            end
        end
    end
    col_types[col_types .== None] = Any

    # create empty DataFrame, and fill
    df = DataFrame(col_types, ks, length(ds))
    for (i,d) in enumerate(ds)
        for (j,k) in enumerate(ks)
            df[i,j] = get(d, k, NA)
        end
    end

    df
end

# If we have a tuple, convert each value in the tuple to a
# DataVector and then pass the converted columns in, hoping for the best
function DataFrame(vals::Any...)
    p = length(vals)
    columns = Array(Any, p)
    for j in 1:p
        if isa(vals[j], AbstractDataVector)
            columns[j] = vals[j]
        else
            columns[j] = DataArray(vals[j])
        end
    end
    column_names = gennames(p)
    DataFrame(columns, Index(column_names))
end

##############################################################################
##
## Basic properties of a DataFrame
##
##############################################################################

colnames(df::DataFrame) = names(df.colindex)
colnames!(df::DataFrame, vals) = names!(df.colindex, vals)

coltypes(df::AbstractDataFrame) = {eltype(df[i]) for i in 1:ncol(df)}

names(df::AbstractDataFrame) = error("Use colnames()")
names!(df::DataFrame, vals::Any) = error("Use colnames!()")

function rename(df::DataFrame, from::Any, to::Any)
    rename(df.colindex, from, to)
end
function rename!(df::DataFrame, from::Any, to::Any)
    rename!(df.colindex, from, to)
end

nrow(df::DataFrame) = ncol(df) > 0 ? length(df.columns[1]) : 0
ncol(df::DataFrame) = length(df.colindex)

Base.size(df::AbstractDataFrame) = (nrow(df), ncol(df))
function Base.size(df::AbstractDataFrame, i::Integer)
    if i == 1
        nrow(df)
    elseif i == 2
        ncol(df)
    else
        throw(ArgumentError("DataFrames have only two dimensions"))
    end
end

Base.length(df::AbstractDataFrame) = ncol(df)
Base.endof(df::AbstractDataFrame) = ncol(df)

Base.ndims(::AbstractDataFrame) = 2

index(df::DataFrame) = df.colindex

##############################################################################
##
## Tools for working with groups of columns
##
##############################################################################

function set_group(df::AbstractDataFrame, newgroup, names)
    set_group(index(df), newgroup, names)
end
function set_groups(df::AbstractDataFrame, gr::Dict{ByteString, Vector{ByteString}})
    set_groups(index(df), gr)
end
function get_groups(df::AbstractDataFrame)
    get_groups(index(df))
end
function rename_group!(df::AbstractDataFrame, a, b)
    rename!(index(df), a, b)
end

function reconcile_groups(olddf::AbstractDataFrame, newdf::AbstractDataFrame)
	# foreach group, restrict range to intersection with newdf colnames
	# add back any groups with non-null range
	old_groups = get_groups(olddf)
	for key in keys(old_groups)
		# this is clunky -- there are better/faster ways of doing this intersection operation
		match_vals = ByteString[]
		for val in old_groups[key]
			if (val in colnames(newdf))
				push!(match_vals, val)
			end
		end
		if !isempty(match_vals)
			set_group(newdf, key, match_vals)
		end
	end
	newdf
end

# TODO: Restore calls to reconcile_groups()

##############################################################################
##
## getindex() definitions
##
##############################################################################

# Cases:
#
# df[SingleColumnIndex] => AbstractDataVector
# df[MultiColumnIndex] => (Sub)?DataFrame
# df[SingleRowIndex, SingleColumnIndex] => Scalar
# df[SingleRowIndex, MultiColumnIndex] => (Sub)?DataFrame
# df[MultiRowIndex, SingleColumnIndex] => (Sub)?AbstractDataVector
# df[MultiRowIndex, MultiColumnIndex] => (Sub)?DataFrame
#
# General Strategy:
#
# Let getindex(df.colindex, col_inds) from Index() handle the resolution
#  of column indices
# Let getindex(df.columns[j], row_inds) from AbstractDataVector() handle
#  the resolution of row indices

typealias ColumnIndex Union(Real, String, Symbol)

# df[SingleColumnIndex] => AbstractDataVector
function Base.getindex(df::DataFrame, col_ind::ColumnIndex)
    selected_column = df.colindex[col_ind]
    return df.columns[selected_column]
end

# df[MultiColumnIndex] => (Sub)?DataFrame
function Base.getindex{T <: ColumnIndex}(df::DataFrame, col_inds::AbstractVector{T})
    selected_columns = df.colindex[col_inds]
    new_columns = df.columns[selected_columns]
    return DataFrame(new_columns, Index(df.colindex.names[selected_columns]))
end

# df[SingleRowIndex, SingleColumnIndex] => Scalar
function Base.getindex(df::DataFrame, row_ind::Real, col_ind::ColumnIndex)
    selected_column = df.colindex[col_ind]
    return df.columns[selected_column][row_ind]
end

# df[SingleRowIndex, MultiColumnIndex] => (Sub)?DataFrame
function Base.getindex{T <: ColumnIndex}(df::DataFrame, row_ind::Real, col_inds::AbstractVector{T})
    selected_columns = df.colindex[col_inds]
    new_columns = {dv[[row_ind]] for dv in df.columns[selected_columns]}
    return DataFrame(new_columns, Index(df.colindex.names[selected_columns]))
end

# df[MultiRowIndex, SingleColumnIndex] => (Sub)?AbstractDataVector
function Base.getindex{T <: Real}(df::DataFrame, row_inds::AbstractVector{T}, col_ind::ColumnIndex)
    selected_column = df.colindex[col_ind]
    return df.columns[selected_column][row_inds]
end

# df[MultiRowIndex, MultiColumnIndex] => (Sub)?DataFrame
function Base.getindex{R <: Real, T <: ColumnIndex}(df::DataFrame, row_inds::AbstractVector{R}, col_inds::AbstractVector{T})
    selected_columns = df.colindex[col_inds]
    new_columns = {dv[row_inds] for dv in df.columns[selected_columns]}
    return DataFrame(new_columns, Index(df.colindex.names[selected_columns]))
end

# Special cases involving expressions
Base.getindex(df::DataFrame, ex::Expr) = getindex(df, with(df, ex))
Base.getindex(df::DataFrame, ex::Expr, c::ColumnIndex) = getindex(df, with(df, ex), c)
Base.getindex{T <: ColumnIndex}(df::DataFrame, ex::Expr, c::AbstractVector{T}) = getindex(df, with(df, ex), c)
Base.getindex(df::DataFrame, c::Real, ex::Expr) = getindex(df, c, with(df, ex))
Base.getindex{T <: Real}(df::DataFrame, c::AbstractVector{T}, ex::Expr) = getindex(df, c, with(df, ex))
Base.getindex(df::DataFrame, ex1::Expr, ex2::Expr) = getindex(df, with(df, ex1), with(df, ex2))

##############################################################################
##
## setindex!()
##
##############################################################################

function create_new_column_from_scalar(df::DataFrame, val::NAtype)
    n = max(nrow(df), 1)
    return DataArray(Array(DEFAULT_COLUMN_TYPE, n), trues(n))
end

function create_new_column_from_scalar(df::DataFrame, val::Any)
    n = max(nrow(df), 1)
    col_data = Array(typeof(val), n)
    for i in 1:n
        col_data[i] = val
    end
    return DataArray(col_data, falses(n))
end

isnextcol(df::DataFrame, col_ind::String) = true
isnextcol(df::DataFrame, col_ind::Symbol) = true
function isnextcol(df::DataFrame, col_ind::Real)
    return ncol(df) + 1 == int(col_ind)
end

function nextcolname(df::DataFrame)
    return string("x", ncol(df) + 1)
end

# Will automatically add a new column if needed
# TODO: Automatically enlarge column to required size?
function insert_single_column!(df::DataFrame,
                               dv::AbstractVector,
                               col_ind::ColumnIndex)
    dv_n, df_n = length(dv), nrow(df)
    if df_n != 0
        if dv_n != df_n
            #dv = repeat(dv, df_n)
            error("New columns must have the same length as old columns")
        end
    end
    if haskey(df.colindex, col_ind)
        j = df.colindex[col_ind]
        df.columns[j] = dv
    else
        if typeof(col_ind) <: String || typeof(col_ind) <: Symbol
            push!(df.colindex, col_ind)
            push!(df.columns, dv)
        else
            if isnextcol(df, col_ind)
                push!(df.colindex, nextcolname(df))
                push!(df.columns, dv)
            else
                println("Column does not exist: $col_ind")
                error("Cannot assign to non-existent column")
            end
        end
    end
    return dv
end

# Will automatically enlarge a scalar to a DataVector if needed
function insert_single_entry!(df::DataFrame, v::Any, row_ind::Real, col_ind::ColumnIndex)
    if nrow(df) <= 1
        dv = DataArray([v], falses(1))
        insert_single_column!(df, dv, col_ind)
        return dv
    else
        try
            df.columns[df.colindex[col_ind]][row_ind] = v
            return v
        catch
            df.columns[df.colindex[col_ind]][row_ind] = NA
            return NA
        end
    end
end

upgrade_vector(v::Vector) = DataArray(v, falses(length(v)))
upgrade_vector(v::Ranges) = DataArray([v], falses(length(v)))
upgrade_vector(v::BitVector) = DataArray(convert(Array{Bool}, v), falses(length(v)))
upgrade_vector(adv::AbstractDataArray) = adv
function upgrade_scalar(df::DataFrame, v::Any)
    n = max(nrow(df), 1)
    DataArray(fill(v, n), falses(n))
end

# df[SingleColumnIndex] = AbstractVector
function Base.setindex!(df::DataFrame,
                v::AbstractVector,
                col_ind::ColumnIndex)
    insert_single_column!(df, upgrade_vector(v), col_ind)
end

# df[SingleColumnIndex] = Scalar (EXPANDS TO MAX(NROW(DF), 1))
function Base.setindex!(df::DataFrame,
                v::Any,
                col_ind::ColumnIndex)
    insert_single_column!(df, upgrade_scalar(df, v), col_ind)
end

# df[MultiColumnIndex] = DataFrame
function Base.setindex!(df::DataFrame,
                new_df::DataFrame,
                col_inds::AbstractVector{Bool})
    setindex!(df, new_df, find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  new_df::DataFrame,
                                  col_inds::AbstractVector{T})
    for i in 1:length(col_inds)
        insert_single_column!(df, new_df[i], col_inds[i])
    end
    return new_df
end

# df[MultiColumnIndex] = AbstractVector (REPEATED FOR EACH COLUMN)
function Base.setindex!(df::DataFrame,
                v::AbstractVector,
                col_inds::AbstractVector{Bool})
    setindex!(df, v, find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  v::AbstractVector,
                                  col_inds::AbstractVector{T})
    dv = upgrade_vector(v)
    for col_ind in col_inds
        insert_single_column!(df, dv, col_ind)
    end
    return dv
end

# df[MultiColumnIndex] = Scalar (REPEATED FOR EACH COLUMN; EXPANDS TO MAX(NROW(DF), 1))
function Base.setindex!(df::DataFrame,
                val::Any,
                col_inds::AbstractVector{Bool})
    setindex!(df, val, find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  val::Any,
                                  col_inds::AbstractVector{T})
    dv = upgrade_scalar(df, val)
    for col_ind in col_inds
        insert_single_column!(df, dv, col_ind)
    end
    return dv
end

# df[SingleRowIndex, SingleColumnIndex] = Scalar
function Base.setindex!(df::DataFrame,
                v::Any,
                row_ind::Real,
                col_ind::ColumnIndex)
    insert_single_entry!(df, v, row_ind, col_ind)
end

# df[SingleRowIndex, MultiColumnIndex] = Scalar (EXPANDS TO MAX(NROW(DF), 1))
function Base.setindex!(df::DataFrame,
                v::Any,
                row_ind::Real,
                col_inds::AbstractVector{Bool})
    setindex!(df, v, row_ind, find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  v::Any,
                                  row_ind::Real,
                                  col_inds::AbstractVector{T})
    for col_ind in col_inds
        insert_single_entry!(df, v, row_ind, col_ind)
    end
    return v
end

# df[SingleRowIndex, MultiColumnIndex] = 1-Row DataFrame
function Base.setindex!(df::DataFrame,
                new_df::DataFrame,
                row_ind::Real,
                col_inds::AbstractVector{Bool})
    setindex!(df, new_df, row_ind, find(col_inds))
end

function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  new_df::DataFrame,
                                  row_ind::Real,
                                  col_inds::AbstractVector{T})
    for j in 1:length(col_inds)
        col_ind = col_inds[j]
        if haskey(df.colindex, col_ind)
            df.columns[df.colindex[col_ind]][row_ind] = new_df[j][1]
        else
            error("Cannot assign into a non-existent position")
        end
    end
    return new_df
end

# df[MultiRowIndex, SingleColumnIndex] = AbstractVector
function Base.setindex!(df::DataFrame,
                v::AbstractVector,
                row_inds::AbstractVector{Bool},
                col_ind::ColumnIndex)
    setindex!(df, v, find(row_inds), col_ind)
end
function Base.assign{T <: Real}(df::DataFrame,
                           v::AbstractVector,
                           row_inds::AbstractVector{T},
                           col_ind::ColumnIndex)
    dv = upgrade_vector(v)
    if haskey(df.colindex, col_ind)
        df.columns[df.colindex[col_ind]][row_inds] = dv
    else
        error("Cannot assign into a non-existent position")
    end
    return dv
end

# df[MultiRowIndex, SingleColumnIndex] = Single Value
function Base.setindex!(df::DataFrame,
                v::Any,
                row_inds::AbstractVector{Bool},
                col_ind::ColumnIndex)
    setindex!(df, v, find(row_inds), col_ind)
end
function Base.assign{T <: Real}(df::DataFrame,
                           v::Any,
                           row_inds::AbstractVector{T},
                           col_ind::ColumnIndex)
    if haskey(df.colindex, col_ind)
        try
            df.columns[df.colindex[col_ind]][row_inds] = v
            return v
        catch
            df.columns[df.colindex[col_ind]][row_inds] = NA
            return NA
        end
    else
        error("Cannot assign into a non-existent position")
    end
end

# df[MultiRowIndex, MultiColumnIndex] = DataFrame
function Base.setindex!(df::DataFrame,
                new_df::DataFrame,
                row_inds::AbstractVector{Bool},
                col_inds::AbstractVector{Bool})
    setindex!(df, new_df, find(row_inds), find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  new_df::DataFrame,
                                  row_inds::AbstractVector{Bool},
                                  col_inds::AbstractVector{T})
    setindex!(df, new_df, find(row_inds), col_inds)
end
function Base.assign{R <: Real}(df::DataFrame,
                           new_df::DataFrame,
                           row_inds::AbstractVector{R},
                           col_inds::AbstractVector{Bool})
    setindex!(df, new_df, row_inds, find(col_inds))
end
function Base.assign{R <: Real, T <: ColumnIndex}(df::DataFrame,
                                             new_df::DataFrame,
                                             row_inds::AbstractVector{R},
                                             col_inds::AbstractVector{T})
    for j in 1:length(col_inds)
        col_ind = col_inds[j]
        if haskey(df.colindex, col_ind)
            df.columns[df.colindex[col_ind]][row_inds] = new_df[:, j]
        else
            error("Cannot assign into a non-existent position")
        end
    end
    return new_df
end

# df[MultiRowIndex, MultiColumnIndex] = AbstractVector
function Base.setindex!(df::DataFrame,
                v::AbstractVector,
                row_inds::AbstractVector{Bool},
                col_inds::AbstractVector{Bool})
    setindex!(df, v, find(row_inds), find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  v::AbstractVector,
                                  row_inds::AbstractVector{Bool},
                                  col_inds::AbstractVector{T})
    setindex!(df, v, find(row_inds), col_inds)
end
function Base.assign{R <: Real}(df::DataFrame,
                           v::AbstractVector,
                           row_inds::AbstractVector{R},
                           col_inds::AbstractVector{Bool})
    setindex!(df, v, row_inds, find(col_inds))
end
function Base.assign{R <: Real, T <: ColumnIndex}(df::DataFrame,
                                             v::AbstractVector,
                                             row_inds::AbstractVector{R},
                                             col_inds::AbstractVector{T})
    dv = upgrade_vector(v)
    for j in 1:length(col_inds)
        col_ind = col_inds[j]
        if haskey(df.colindex, col_ind)
            df.columns[df.colindex[col_ind]][row_inds] = dv
        else
            error("Cannot assign into a non-existent position")
        end
    end
    return dv
end

# df[MultiRowIndex, MultiColumnIndex] = Single Item
function Base.setindex!(df::DataFrame,
                v::Any,
                row_inds::AbstractVector{Bool},
                col_inds::AbstractVector{Bool})
    setindex!(df, v, find(row_inds), find(col_inds))
end
function Base.assign{T <: ColumnIndex}(df::DataFrame,
                                  v::Any,
                                  row_inds::AbstractVector{Bool},
                                  col_inds::AbstractVector{T})
    setindex!(df, v, find(row_inds), col_inds)
end
function Base.assign{R <: Real}(df::DataFrame,
                           v::Any,
                           row_inds::AbstractVector{R},
                           col_inds::AbstractVector{Bool})
    setindex!(df, v, row_inds, find(col_inds))
end
function Base.assign{R <: Real, T <: ColumnIndex}(df::DataFrame,
                                             v::Any,
                                             row_inds::AbstractVector{R},
                                             col_inds::AbstractVector{T})
    for j in 1:length(col_inds)
        col_ind = col_inds[j]
        if haskey(df.colindex, col_ind)
            try
                df.columns[df.colindex[col_ind]][row_inds] = v
                return v
            catch
                df.columns[df.colindex[col_ind]][row_inds] = NA
                return NA
            end
        else
            error("Cannot assign into a non-existent position")
        end
    end
end

# Special deletion assignment
Base.setindex!(df::DataFrame, x::Nothing, icol::Int) = delete!(df, icol)

# Special cases involving expressions
function Base.setindex!(df::DataFrame, val::Any, ex::Expr)
    setindex!(df, val, with(df, ex))
end
function Base.setindex!(df::DataFrame, val::Any, ex::Expr, c::ColumnIndex)
    setindex!(df, val, with(df, ex), c)
end
function Base.assign{T <: ColumnIndex}(df::DataFrame, val::Any, ex::Expr, c::AbstractVector{T})
    setindex!(df, val, with(df, ex), c)
end
function Base.setindex!(df::DataFrame, val::Any, c::Real, ex::Expr)
    setindex!(df, val, c, with(df, ex))
end
function Base.assign{T <: Real}(df::DataFrame, val::Any, c::AbstractVector{T}, ex::Expr)
    setindex!(df, val, c, with(df, ex))
end
function Base.setindex!(df::DataFrame, val::Any, ex1::Expr, ex2::Expr)
    setindex!(df, val, with(df, ex1), with(df, ex2))
end

##############################################################################
##
## Associative methods
##
##############################################################################

Base.haskey(df::AbstractDataFrame, key::Any) = haskey(index(df), key)
Base.get(df::AbstractDataFrame, key::Any, default::Any) = haskey(df, key) ? df[key] : default
Base.keys(df::AbstractDataFrame) = keys(index(df))
Base.values(df::DataFrame) = df.columns
Base.empty!(df::DataFrame) = DataFrame() # TODO: Make this work right

Base.isempty(df::AbstractDataFrame) = ncol(df) == 0

function Base.insert!(df::AbstractDataFrame, index::Int, item::Any, name::Any)
    @assert 0 < index <= ncol(df) + 1
    df = copy(df)
    df[name] = item
    # rearrange:
    df[[1:index-1, end, index:end-1]]
end

function Base.insert!(df::AbstractDataFrame, df2::AbstractDataFrame)
    @assert nrow(df) == nrow(df2) || nrow(df) == 0
    df = copy(df)
    for n in colnames(df2)
        df[n] = df2[n]
    end
    df
end

##############################################################################
##
## Copying
##
##############################################################################

# copy of a data frame does a shallow copy
function Base.copy(df::DataFrame)
	newdf = DataFrame(copy(df.columns), colnames(df))
	reconcile_groups(df, newdf)
end
function Base.deepcopy(df::DataFrame)
    newdf = DataFrame([copy(x) for x in df.columns], colnames(df))
    reconcile_groups(df, newdf)
end
#deepcopy_with_groups(df::DataFrame) = DataFrame([copy(x) for x in df.columns], colnames(df), get_groups(df))

##############################################################################
##
## head() and tail()
##
##############################################################################

DataArrays.head(df::AbstractDataFrame, r::Int) = df[1:min(r,nrow(df)), :]
DataArrays.head(df::AbstractDataFrame) = head(df, 6)
DataArrays.tail(df::AbstractDataFrame, r::Int) = df[max(1,nrow(df)-r+1):nrow(df), :]
DataArrays.tail(df::AbstractDataFrame) = tail(df, 6)

# get the structure of a DF
function Base.dump(io::IO, x::AbstractDataFrame, n::Int, indent)
    println(io, typeof(x), "  $(nrow(x)) observations of $(ncol(x)) variables")
    gr = get_groups(x)
    if length(gr) > 0
        pretty_show(io, gr)
        println(io)
    end
    if n > 0
        for col in colnames(x)[1:end]
            print(io, indent, "  ", col, ": ")
            dump(io, x[col], n - 1, string(indent, "  "))
        end
    end
end

function Base.dump(io::IO, x::AbstractDataVector, n::Int, indent)
    println(io, typeof(x), "(", length(x), ") ", x[1:min(4, end)])
end

# summarize the columns of a DF
# if the column's base type derives from Number, 
# compute min, 1st quantile, median, mean, 3rd quantile, and max
# filtering NAs, which are reported separately
# if boolean, report trues, falses, and NAs
# if anything else, punt.
# Note that R creates a summary object, which has a print method. That's
# a reasonable alternative to this.
describe(dv::AbstractDataVector) = describe(STDOUT, dv)
describe(df::DataFrame) = describe(STDOUT, df)
function describe{T<:Number}(io, dv::AbstractDataVector{T})
    if all(isna(dv))
        println(io, " * All NA * ")
        return
    end
    filtered = float(removeNA(dv))
    qs = quantile(filtered, [0, .25, .5, .75, 1])
    statNames = ["Min", "1st Qu.", "Median", "Mean", "3rd Qu.", "Max"]
    statVals = [qs[1:3], mean(filtered), qs[4:5]]
    for i = 1:6
        println(io, string(rpad(statNames[i], 8, " "), " ", string(statVals[i])))
    end
    nas = sum(isna(dv))
    println(io, "NAs      $nas")
    println(io, "NA%      $(round(nas*100/length(dv), 2))%")
    return
end
function describe{T}(io, dv::AbstractDataVector{T})
    ispooled = isa(dv, PooledDataVector) ? "Pooled " : ""
    # if nothing else, just give the length and element type and NA count
    println(io, "Length  $(length(dv))")
    println(io, "Type    $(ispooled)$(string(eltype(dv)))")
    println(io, "NAs     $(sum(isna(dv)))")
    println(io, "NA%     $(round(sum(isna(dv))*100/length(dv), 2))%")
    println(io, "Unique  $(length(unique(dv)))") 
    return
end

# TODO: clever layout in rows
# TODO: AbstractDataFrame
function describe(io, df::AbstractDataFrame)
    for c in 1:ncol(df)
        col = df[c]
        println(io, colnames(df)[c])
        describe(io, col)
        println(io, )
    end
end

##############################################################################
##
## We use SubDataFrame's to maintain a reference to a subset of a DataFrame
## without making copies.
##
##############################################################################

# a SubDataFrame is a lightweight wrapper around a DataFrame used most frequently in
# split/apply sorts of operations.
type SubDataFrame <: AbstractDataFrame
    parent::DataFrame
    rows::Vector{Int} # maps from subdf row indexes to parent row indexes
    
    function SubDataFrame(parent::DataFrame, rows::Vector{Int})
        if any(rows .< 1)
            error("all SubDataFrame indices must be > 0")
        end
        if length(rows) > 0 && maximum(rows) > nrow(parent)
            error("all SubDataFrame indices must be <= the number of rows of the DataFrame")
        end
        new(parent, rows)
    end
end

Base.sub(D::DataFrame, r, c) = sub(D[[c]], r)    # If columns are given, pass in a subsetted parent D.
                                            # Columns are not copies, so it's not expensive.
Base.sub(D::DataFrame, r::Int) = sub(D, [r])
Base.sub(D::DataFrame, rs::Vector{Int}) = SubDataFrame(D, rs)
Base.sub(D::DataFrame, r) = sub(D, getindex(SimpleIndex(nrow(D)), r)) # this is a wacky fall-through that uses light-weight fake indexes!
Base.sub(D::DataFrame, ex::Expr) = sub(D, with(D, ex))

Base.sub(D::SubDataFrame, r, c) = sub(D[[c]], r)
Base.sub(D::SubDataFrame, r::Int) = sub(D, [r])
Base.sub(D::SubDataFrame, rs::Vector{Int}) = SubDataFrame(D.parent, D.rows[rs])
Base.sub(D::SubDataFrame, r) = sub(D, getindex(SimpleIndex(nrow(D)), r)) # another wacky fall-through
Base.sub(D::SubDataFrame, ex::Expr) = sub(D, with(D, ex))
const subset = sub

Base.filter(ex::Expr, df::AbstractDataFrame) = subset(df, ex)
Base.select(ex::Expr, df::AbstractDataFrame) = subset(df, ex)

Base.getindex(df::SubDataFrame, c) = df.parent[df.rows, c]
Base.getindex(df::SubDataFrame, r, c) = df.parent[df.rows[r], c]

Base.setindex!(df::SubDataFrame, v, c) = (df.parent[df.rows, c] = v)
Base.setindex!(df::SubDataFrame, v, r, c) = (df.parent[df.rows[r], c] = v)

nrow(df::SubDataFrame) = length(df.rows)
ncol(df::SubDataFrame) = ncol(df.parent)
colnames(df::SubDataFrame) = colnames(df.parent) 

# Associative methods:
index(df::SubDataFrame) = index(df.parent)

# delete!() deletes columns; deleterows!() deletes rows
# delete!(df, 1)
# delete!(df, "old")
function Base.delete!(df::DataFrame, inds::Vector{Int})
    for i in 1:length(inds)
        ind = inds[i] - i + 1
        if 1 <= ind <= ncol(df)
            splice!(df.columns, ind)
            delete!(df.colindex, ind)
        else
            throw(ArgumentError("Can't delete a non-existent DataFrame column"))
        end
    end
    return df
end
Base.delete!(df::DataFrame, c::Int) = delete!(df, [c])
Base.delete!(df::DataFrame, c::Any) = delete!(df, df.colindex[c])
Base.delete!(df::SubDataFrame, c::Any) = SubDataFrame(del(df.parent, c), df.rows)

# deleterows!()
function deleterows!(df::DataFrame, keep_inds::Vector{Int})
    for i in 1:ncol(df)
        df.columns[i] = df.columns[i][keep_inds]
    end
end

function without(df::DataFrame, icols::Vector{Int})
    newcols = _setdiff([1:ncol(df)], icols)
    if length(newcols) == 0
        throw(ArgumentError("Empty DataFrame generated by without()"))
    end
    df[newcols]
end
without(df::DataFrame, i::Int) = without(df, [i])
without(df::DataFrame, c::Any) = without(df, df.colindex[c])
without(df::SubDataFrame, c::Any) = SubDataFrame(without(df.parent, c), df.rows)

#### cbind, rbind, hcat, vcat
# hcat() is just cbind()
# rbind(df, ...) only accepts data frames. Finds union of columns, maintaining order
# of first df. Missing data becomes NAs.
# vcat() is just rbind()
 
# two-argument form, two dfs, references only
function Base.hcat(df1::DataFrame, df2::DataFrame)
    # If df1 had metadata, we should copy that.
    colindex = Index(make_unique([colnames(df1), colnames(df2)]))
    columns = [df1.columns, df2.columns]
    d = DataFrame(columns, colindex)  
    set_groups(d, get_groups(df1))
    set_groups(d, get_groups(df2))
    return d
end
Base.hcat{T}(df::DataFrame, x::DataVector{T}) = hcat(df, DataFrame({x}))
Base.hcat{T}(df::DataFrame, x::Vector{T}) = hcat(df, DataFrame({DataArray(x)}))
Base.hcat{T}(df::DataFrame, x::T) = hcat(df, DataFrame({DataArray([x])}))

# three-plus-argument form recurses
Base.hcat(a::DataFrame, b, c...) = hcat(hcat(a, b), c...)
cbind(args...) = hcat(args...)

is_group(df::AbstractDataFrame, name::ByteString) = is_group(index(df), name)

Base.similar(df::DataFrame, dims) = 
    DataFrame([similar(x, dims) for x in df.columns], colnames(df)) 

Base.similar(df::SubDataFrame, dims) = 
    DataFrame([similar(df[x], dims) for x in colnames(df)], colnames(df)) 

Base.zeros{T<:String}(::Type{T},args...) = fill("",args...) # needed for string arrays in the `nas` method above

nas{T}(dv::DataArray{T}, dims) =   # TODO move to datavector.jl?
    DataArray(zeros(T, dims), fill(true, dims))
 
nas{T,R}(dv::PooledDataVector{T,R}, dims) =
    PooledDataArray(DataArrays.RefArray(fill(one(R), dims)), dv.pool)

nas(df::DataFrame, dims) = 
    DataFrame([nas(x, dims) for x in df.columns], colnames(df)) 

nas(df::SubDataFrame, dims) = 
    DataFrame([nas(df[x], dims) for x in colnames(df)], colnames(df)) 

vecbind_type{T}(::Vector{T}) = Vector{T}
vecbind_type{T<:AbstractVector}(x::T) = Vector{eltype(x)}
vecbind_type{T<:AbstractDataVector}(x::T) = DataVector{eltype(x)}
vecbind_type{T}(::PooledDataVector{T}) = DataVector{T}

vecbind_promote_type{T1,T2}(x::Type{Vector{T1}}, y::Type{Vector{T2}}) = Array{promote_type(eltype(x), eltype(y)),1}
vecbind_promote_type{T1,T2}(x::Type{DataVector{T1}}, y::Type{DataVector{T2}}) = DataArray{promote_type(eltype(x), eltype(y)),1}
vecbind_promote_type{T1,T2}(x::Type{Vector{T1}}, y::Type{DataVector{T2}}) = DataArray{promote_type(eltype(x), eltype(y)),1}
vecbind_promote_type{T1,T2}(x::Type{DataVector{T1}}, y::Type{Vector{T2}}) = DataArray{promote_type(eltype(x), eltype(y)),1}
vecbind_promote_type(a, b, c, ds...) = vecbind_promote_type(a, vecbind_promote_type(b, c, ds...))
vecbind_promote_type(a, b, c) = vecbind_promote_type(a, vecbind_promote_type(b, c))

function vecbind_promote_type(a::AbstractVector)
    res = None
    if isdefined(a, 1)
        if length(a) == 1
            return a[1]
        else
            if isdefined(a, 2)
                res = vecbind_promote_type(a[1], a[2])
            else
                res = a[1]
            end
        end
    end
    for i in 3:length(a)
        if isdefined(a, i)
            res = vecbind_promote_type(res, a[i])
        end
    end
    return res
end

constructor{T}(::Type{Vector{T}}, args...) = Array(T, args...)
constructor{T}(::Type{DataVector{T}}, args...) = DataArray(T, args...)

function vecbind(xs::AbstractVector...)
    V = vecbind_promote_type(map(vecbind_type, {xs...}))
    len = sum(length, xs)
    res = constructor(V, len)
    k = 1
    for i in 1:length(xs)
        for j in 1:length(xs[i])
            res[k] = xs[i][j]
            k += 1
        end
    end
    res
end
function vecbind(xs::PooledDataVector...)
    vecbind(map(x -> convert(DataArray, x), xs)...)
end

Base.vcat(df::AbstractDataFrame) = df
Base.vcat{T<:AbstractDataFrame}(dfs::Vector{T}) = vcat(dfs...)
function Base.vcat(dfs::AbstractDataFrame...)
    Nrow = sum(nrow, dfs)
    # build up column names and types
    colnams = colnames(dfs[1])
    coltyps = coltypes(dfs[1])
    for i in 2:length(dfs)
        cni = colnames(dfs[i])
        cti = coltypes(dfs[i])
        for j in 1:length(cni)
            cn = cni[j]
            if length(findin([cn], colnams)) == 0  # new column
                push!(colnams, cn)
                push!(coltyps, cti[j])
            end
        end
    end
    Ncol = length(colnams)
    res = DataFrame()
    for i in 1:Ncol
        coldata = {}
        for df in dfs
            push!(coldata,
                  get(df,
                      colnams[i],
                      DataArray(coltyps[i], size(df, 1))))
        end
        res[colnams[i]] = vcat(coldata...)
    end
    res
end

rbind(args...) = vcat(args...)

# DF row operations -- delete and append
# df[1] = nothing
# df[1:3] = nothing
# df3 = rbind(df1, df2...)
# rbind!(df1, df2...)


# split-apply-combine
# co(ap(myfun,
#    sp(df, ["region", "product"])))
# (|>)(x, f::Function) = f(x)
# split(df, ["region", "product"]) |> (apply(nrow)) |> mean
# apply(f::function) = (x -> map(f, x))
# split(df, ["region", "product"]) |> @@@)) |> mean
# how do we add col names to the name space?
# transform(df, :(cat=dog*2, clean=proc(dirty)))
# summarise(df, :(cat=sum(dog), all=string(strs)))

function with(d::Associative, ex::Expr)
    # Note: keys must by symbols
    replace_symbols(x, d::Dict) = x
    replace_symbols(e::Expr, d::Dict) = Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_symbols(x, d), e.args))...)
    function replace_symbols{K,V}(s::Symbol, d::Dict{K,V})
        if (K == Any || K == Symbol) && haskey(d, s)
            :(_D[$(Meta.quot(s))])
        elseif (K == Any || K <: String) && haskey(d, string(s))
            :(_D[$(string(s))])
        else
            s
        end
    end
    ex = replace_symbols(ex, d)
    global _ex = ex
    f = @eval (_D) -> $ex
    f(d)
end

function within!(d::Associative, ex::Expr)
    # Note: keys must by symbols
    replace_symbols(x, d::Associative) = x
    function replace_symbols{K,V}(e::Expr, d::Associative{K,V})
        if e.head == :(=) # replace left-hand side of assignments:
            if (K == Symbol || (K == Any && isa(collect(keys(d))[1], Symbol)))
                exref = Meta.quot(e.args[1])
                if !haskey(d, e.args[1]) # Dummy assignment to reserve a slot.
                                      # I'm not sure how expensive this is.
                    d[e.args[1]] = collect(values(d))[1]
                end
            else
                exref = string(e.args[1])
                if !haskey(d, exref) # dummy assignment to reserve a slot
                    d[exref] = collect(values(d))[1]
                end
            end
            Expr(e.head,
                 vcat({:(_D[$exref])}, map(x -> replace_symbols(x, d), e.args[2:end]))...)
        else
            Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_symbols(x, d), e.args))...)
        end
    end
    function replace_symbols{K,V}(s::Symbol, d::Associative{K,V})
        if (K == Any || K == Symbol) && haskey(d, s)
            :(_D[$(Meta.quot(s))])
        elseif (K == Any || K <: String) && haskey(d, string(s))
            :(_D[$(string(s))])
        else
            s
        end
    end
    ex = replace_symbols(ex, d)
    f = @eval (_D) -> begin
        $ex
        _D
    end
    f(d)
end



mygetindex(d, key) = getindex(d, key)
myref{K<:String,V}(d::Associative{K,V}, key) = getindex(d, string(key))
mygetindex(d::AbstractDataFrame, key::Symbol) = getindex(d, string(key))

myhas(d, key) = haskey(d, key)
myhas{K<:String,V}(d::Associative{K,V}, key) = haskey(d, string(key))
myhas(d::AbstractDataFrame, key::Symbol) = haskey(d, string(key))

bestkey(d, key) = key
bestkey{K<:String,V}(d::Associative{K,V}, key) = string(key)
bestkey(d::AbstractDataFrame, key) = string(key)
bestkey(d::NamedArray, key) = string(key)

replace_syms(x) = x
replace_syms(s::Symbol) = :( myhas(d, $(Meta.quot(s))) ? mygetindex(d, $(Meta.quot(s))) : $(esc(s)) )
replace_syms(e::Expr) = Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_syms(x), e.args))...)

## quot(value) = Base.splicedexpr(:quote, value)  # Toivo special

function transform_helper(d, args...)
    exa = {:(local d = $(esc(d)))}
    for ex in args
        left = ex.args[1]
        right = replace_syms(ex.args[2])
        push!(exa,
            :(d[bestkey(d, $(Meta.quot(left)))] = $(right)))
    end
    push!(exa, :d)
    Expr(:block, exa...)
end

macro transform(df, args...)
    transform_helper(df, args...)
end

macro DataFrame(args...)
    :(DataFrame( @transform(NamedArray(), $(map(esc, args)...)) ))
end



    
function based_on(d::Associative, ex::Expr)
    # Note: keys must by symbols
    replace_symbols(x, d::Associative) = x
    function replace_symbols{K,V}(e::Expr, d::Associative{K,V})
        if e.head == :(=) # replace left-hand side of assignments:
            if (K == Symbol || (K == Any && isa(collect(keys(d))[1], Symbol)))
                exref = Meta.quot(e.args[1])
                if !haskey(d, e.args[1]) # Dummy assignment to reserve a slot.
                                      # I'm not sure how expensive this is.
                    d[e.args[1]] = collect(values(d))[1]
                end
            else
                exref = string(e.args[1])
                if !haskey(d, exref) # dummy assignment to reserve a slot
                    d[exref] = collect(values(d))[1]
                end
            end
            Expr(e.head,
                 vcat({:(_ND[$exref])}, map(x -> replace_symbols(x, d), e.args[2:end]))...)
        else
            Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_symbols(x, d), e.args))...)
        end
    end
    function replace_symbols{K,V}(s::Symbol, d::Associative{K,V})
        if (K == Any || K == Symbol) && haskey(d, s)
            :(_D[$(Meta.quot(s))])
        elseif (K == Any || K <: String) && haskey(d, string(s))
            :(_D[$(string(s))])
        else
            s
        end
    end
    ex = replace_symbols(ex, d)
    f = @eval (_D) -> begin
        _ND = similar(_D)
        $ex
        _ND
    end
    f(d)
end

function within!(df::AbstractDataFrame, ex::Expr)
    # By-column operation within a DataFrame that allows replacing or adding columns.
    # Returns the transformed DataFrame.
    #   
    # helper function to replace symbols in ex with a reference to the
    # appropriate column in df
    replace_symbols(x, syms::Dict) = x
    function replace_symbols(e::Expr, syms::Dict)
        if e.head == :(=) # replace left-hand side of assignments:
            if !haskey(syms, string(e.args[1]))
                syms[string(e.args[1])] = length(syms) + 1
            end
            Expr(e.head,
                 vcat({:(_DF[$(string(e.args[1]))])}, map(x -> replace_symbols(x, syms), e.args[2:end]))...)
        else
            Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_symbols(x, syms), e.args))...)
        end
    end
    function replace_symbols(s::Symbol, syms::Dict)
        if (string(s) in keys(syms))
            :(_DF[$(syms[string(s)])])
        else
            s
        end
    end
    # Make a dict of colnames and column positions
    cn_dict = Dict(colnames(df), 1:ncol(df))
    ex = replace_symbols(ex, cn_dict)
    f = @eval (_DF) -> begin
        $ex
        _DF
    end
    f(df)
end

within(x, args...) = within!(copy(x), args...)

function based_on_f(df::AbstractDataFrame, ex::Expr)
    # Returns a function for use on an AbstractDataFrame
    
    # helper function to replace symbols in ex with a reference to the
    # appropriate column in a new df
    replace_symbols(x, syms::Dict) = x
    function replace_symbols(e::Expr, syms::Dict)
        if e.head == :(=) # replace left-hand side of assignments:
            if !haskey(syms, string(e.args[1]))
                syms[string(e.args[1])] = length(syms) + 1
            end
            Expr(e.head,
                 vcat({:(_col_dict[$(string(e.args[1]))])}, map(x -> replace_symbols(x, syms), e.args[2:end]))...)
        else
            Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_symbols(x, syms), e.args))...)
        end
    end
    function replace_symbols(s::Symbol, syms::Dict)
        if (string(s) in keys(syms))
            :(_DF[$(syms[string(s)])])
        else
            s
        end
    end
    # Make a dict of colnames and column positions
    cn_dict = Dict(colnames(df), [1:ncol(df)])
    ex = replace_symbols(ex, cn_dict)
    @eval (_DF) -> begin
        _col_dict = NamedArray()
        $ex
        DataFrame(_col_dict)
    end
end
function based_on(df::AbstractDataFrame, ex::Expr)
    # By-column operation within a DataFrame.
    # Returns a new DataFrame.
    f = based_on_f(df, ex)
    f(df)
end

function with(df::AbstractDataFrame, ex::Expr)
    # By-column operation with the columns of a DataFrame.
    # Returns the result of evaluating ex.
    
    # helper function to replace symbols in ex with a reference to the
    # appropriate column in df
    replace_symbols(x, syms::Dict) = x
    replace_symbols(e::Expr, syms::Dict) = Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_symbols(x, syms), e.args))...)
    function replace_symbols(s::Symbol, syms::Dict)
        if (string(s) in keys(syms))
            :(_DF[$(syms[string(s)])])
        else
            s
        end
    end
    # Make a dict of colnames and column positions
    cn_dict = Dict(colnames(df), [1:ncol(df)])
    ex = replace_symbols(ex, cn_dict)
    f = @eval (_DF) -> $ex
    f(df)
end

with(df::AbstractDataFrame, s::Symbol) = df[string(s)]

# add function curries to ease pipelining:
with(e::Expr) = x -> with(x, e)
within(e::Expr) = x -> within(x, e)
within!(e::Expr) = x -> within!(x, e)
based_on(e::Expr) = x -> based_on(x, e)

# allow pipelining straight to an expression using within!:
(|>)(x::AbstractDataFrame, e::Expr) = within!(x, e)




##
## Miscellaneous
##

function complete_cases(df::AbstractDataFrame)
    ## Returns a Vector{Bool} of indexes of complete cases (rows with no NA's).
    res = !isna(df[1])
    for i in 2:ncol(df)
        res &= !isna(df[i])
    end
    res
end

complete_cases!(df::AbstractDataFrame) = deleterows!(df, find(complete_cases(df)))

function DataArrays.array(adf::AbstractDataFrame)
    n, p = size(adf)
    # TODO: Replace when tunion() is added to Base
    t = reduce(earliest_common_ancestor, coltypes(adf))
    res = Array(t, n, p)
    for i in 1:n
        for j in 1:p
            res[i, j] = adf[i, j]
        end
    end
    return res
end

function DataArrays.DataArray(adf::AbstractDataFrame, t::Type)
    n, p = size(adf)
    dm = DataArray(t, n, p)
    for i in 1:n
        for j in 1:p
            dm[i, j] = adf[i, j]
        end
    end
    return dm
end
function DataArrays.DataArray(adf::AbstractDataFrame)
    # TODO: Replace when tunion() is added to Base
    t = reduce(earliest_common_ancestor, coltypes(adf))
    DataArray(adf, t)
end

function duplicated(df::AbstractDataFrame)
    # Return a Vector{Bool} indicated whether the row is a duplicate
    # of a prior row.
    res = fill(false, nrow(df))
    di = Dict()
    for i in 1:nrow(df)
        if haskey(di, array(df[i, :])) # Used to convert to Any type
            res[i] = true
        else
            di[array(df[i, :])] = 1 # Used to convert to Any type
        end
    end
    res
end

function drop_duplicates!(df::AbstractDataFrame)
    deleterows!(df, find(!duplicated(df)))
end

# Unique rows of an AbstractDataFrame.        
Base.unique(df::AbstractDataFrame) = df[!duplicated(df), :] 

function duplicatedkey(df::AbstractDataFrame)
    # Here's another (probably a lot faster) way to do `duplicated`
    # by grouping on all columns. It will fail if columns cannot be
    # made into PooledDataVector's.
    gd = groupby(df, colnames(df))
    idx = [1:length(gd.idx)][gd.idx][gd.starts]
    res = fill(true, nrow(df))
    res[idx] = false
    res
end

function DataArrays.isna(df::DataFrame)
    results = BitArray(size(df))
    for i in 1:nrow(df)
        for j in 1:ncol(df)
            results[i, j] = isna(df[i, j])
        end
    end
    return results
end

function Base.isnan(df::DataFrame)
    p = ncol(df)
    res_columns = Array(Any, p)
    for j in 1:p
        res_columns[j] = isnan(df[j])
    end
    return DataFrame(res_columns, colnames(df))
end

function Base.isfinite(df::DataFrame)
    p = ncol(df)
    res_columns = Array(Any, p)
    for j in 1:p
        res_columns[j] = isfinite(df[j])
    end
    return DataFrame(res_columns, colnames(df))
end

# TODO: Use cor and cov for DataMatrix to do this
function Base.cor(df::DataFrame)
    numeric_cols = find(map(t -> t <: Number, coltypes(df)))
    cor(array(df[:, numeric_cols]))
end
function Base.cov(df::DataFrame)
    numeric_cols = find(map(t -> t <: Number, coltypes(df)))
    cov(array(df[:, numeric_cols]))
end

function clean_colnames!(df::DataFrame)
    old_names = map(strip, colnames(df))
    new_names = map(n -> replace(n, r"\W", "_"), old_names)
    colnames!(df, new_names)
    return
end

function Base.flipud(df::DataFrame)
    return df[reverse(1:nrow(df)), :]
end

function flipud!(df::DataFrame)
    df[1:nrow(df), :] = df[reverse(1:nrow(df)), :]
    return
end


##############################################################################
##
## Sorting
##
##############################################################################

#########################################
## Permutation & Ordering types/functions
#########################################
# Sorting in Julia works through Orderings, where each ordering is a type
# which defines a comparison function lt(o::Ord, a, b).

# UserColOrdering: user ordering of a column; this is just a convenience container
#                  which allows a user to specify column specific orderings
#                  with "order(column, rev=true,...)"

type UserColOrdering{T<:ColumnIndex}
    col::T
    kwargs
end

# This is exported, and lets a user define orderings for a particular column
order{T<:ColumnIndex}(col::T; kwargs...) = UserColOrdering{T}(col, kwargs)

# Allow getting the column even if it is not wrapped in a UserColOrdering
_getcol(o::UserColOrdering) = o.col
_getcol(x) = x

###
# Get an Ordering for a single column
###
function ordering(col_ord::UserColOrdering, lt::Function, by::Function, rev::Bool, order::Ordering)
    for (k,v) in col_ord.kwargs
        if     k == :lt;    lt    = v
        elseif k == :by;    by    = v
        elseif k == :rev;   rev   = v
        elseif k == :order; order = v
        else
            error("Unknown keyword argument: ", string(k))
        end
    end

    ord(lt,by,rev,order)
end

ordering(col::ColumnIndex, lt::Function, by::Function, rev::Bool, order::Ordering) =
             ord(lt,by,rev,order)

# DFPerm: defines a permutation on a particular DataFrame, using
#         a single ordering (O<:Ordering) or a list of column orderings
#         (O<:AbstractVector{Ordering}), one per DataFrame column
#
#         If a user only specifies a few columns, the DataFrame
#         contained in the DFPerm only contains those columns, and
#         the permutation induced by this ordering is used to 
#         sort the original (presumably larger) DataFrame

type DFPerm{O<:Union(Ordering, AbstractVector), DF<:AbstractDataFrame} <: Ordering
    ord::O
    df::DF
end

function DFPerm{O<:Ordering}(ords::AbstractVector{O}, df::AbstractDataFrame)
    if length(ords) != ncol(df)
        error("DFPerm: number of column orderings does not equal the number of DataFrame columns")
    end
    DFPerm{AbstractVector{O}, typeof(df)}(ords, df)
end

DFPerm{O<:Ordering}(o::O, df::AbstractDataFrame) = DFPerm{O,typeof(df)}(o,df)

# For sorting, a and b are row indices (first two lt definitions)
# For issorted, the default row iterator returns SubDataFrames instead,
# so two more lt function is defined below
function Base.Sort.lt{V<:AbstractVector}(o::DFPerm{V}, a, b)
    for i = 1:ncol(o.df)
        if lt(o.ord[i], o.df[a,i], o.df[b,i])
            return true
        end
        if lt(o.ord[i], o.df[b,i], o.df[a,i])
            return false
        end
    end
    false
end

function Base.Sort.lt{O<:Ordering}(o::DFPerm{O}, a, b)
    for i = 1:ncol(o.df)
        if lt(o.ord, o.df[a,i], o.df[b,i])
            return true
        end
        if lt(o.ord, o.df[b,i], o.df[a,i])
            return false
        end
    end
    false
end

function Base.Sort.lt{V<:AbstractVector}(o::DFPerm{V}, a::AbstractDataFrame, b::AbstractDataFrame)
    for i = 1:ncol(o.df)
        if lt(o.ord[i], a[1,i], b[1,i])
            return true
        end
        if lt(o.ord[i], b[1,i], a[1,i])
            return false
        end
    end
    false
end

function Base.Sort.lt{O<:Ordering}(o::DFPerm{O}, a::AbstractDataFrame, b::AbstractDataFrame)
    for i = 1:ncol(o.df)
        if lt(o.ord, a[1,i], b[1,i])
            return true
        end
        if lt(o.ord, b[1,i], a[1,i])
            return false
        end
    end
    false
end

###
# Get an Ordering for a DataFrame
###

################
## Case 1: no columns requested, so sort by all columns using requested order
################
## Case 1a: single order
######
ordering(df::AbstractDataFrame, lt::Function, by::Function, rev::Bool, order::Ordering) =
    DFPerm(ord(lt, by, rev, order), df)

######
## Case 1b: lt, by, rev, and order are Arrays
######
function ordering(df::AbstractDataFrame, lt::AbstractVector{Function}, by::AbstractVector{Function}, rev::AbstractVector{Bool}, order::AbstractVector)
    if !(length(lt) == length(by) == length(rev) == length(order) == size(df,2))
        throw(ArgumentError("Orderings must be specified for all DataFrame columns"))
    end
    DFPerm([ord(_lt, _by, _rev, _order) for (_lt, _by, _rev, _order) in zip(lt, by, rev, order)], df)
end

################
## Case 2:  Return a regular permutation when there's only one column
################
## Case 2a: The column is given directly
######
ordering(df::AbstractDataFrame, col::ColumnIndex, lt::Function, by::Function, rev::Bool, order::Ordering) =
    Perm(ord(lt, by, rev, order), df[col])

######
## Case 2b: The column is given as a UserColOrdering
######
ordering(df::AbstractDataFrame, col_ord::UserColOrdering, lt::Function, by::Function, rev::Bool, order::Ordering) =
    Perm(ordering(col_ord, lt, by, rev, order), df[col_ord.col])

################
## Case 3:  General case: cols is an iterable of a combination of ColumnIndexes and UserColOrderings
################
## Case 3a: None of lt, by, rev, or order is an Array
######
function ordering(df::AbstractDataFrame, cols::AbstractVector, lt::Function, by::Function, rev::Bool, order::Ordering)

    if length(cols) == 0
        return ordering(df, lt, by, rev, order)
    end

    if length(cols) == 1
        return ordering(df, cols[1], lt, by, rev, order)
    end

    # Collect per-column ordering info

    ords = Ordering[]
    newcols = Int[]

    for col in cols
        push!(ords, ordering(col, lt, by, rev, order))
        push!(newcols, index(df)[(_getcol(col))])
    end

    # Simplify ordering when all orderings are the same
    if all([ords[i] == ords[1] for i = 2:length(ords)])
        return DFPerm(ords[1], df[newcols])
    end

    return DFPerm(ords, df[newcols])
end

######
# Case 3b: cols, lt, by, rev, and order are all arrays
######
function ordering(df::AbstractDataFrame, cols::AbstractVector,
                  lt::AbstractVector{Function}, by::AbstractVector{Function}, rev::AbstractVector{Bool}, order::AbstractVector)

    if !(length(lt) == length(by) == length(rev) == length(order))
        throw(ArgumentError("All ordering arguments must be 1 or the same length."))
    end

    if length(cols) == 0
        return ordering(df, lt, by, rev, order)
    end

    if length(lt) != length(cols)
        throw(ArgumentError("All ordering arguments must be 1 or the same length as the number of columns requested."))
    end

    if length(cols) == 1
        return ordering(df, cols[1], lt[1], by[1], rev[1], order[1])
    end

    # Collect per-column ordering info

    ords = Ordering[]
    newcols = Int[]

    for i in 1:length(cols)
        push!(ords, ordering(cols[i], lt[i], by[i], rev[i], order[i]))
        push!(newcols, index(df)[(_getcol(cols[i]))])
    end

    # Simplify ordering when all orderings are the same
    if all([ords[i] == ords[1] for i = 2:length(ords)])
        return DFPerm(ords[1], df[newcols])
    end

    return DFPerm(ords, df[newcols])
end

######
## At least one of lt, by, rev, or order is an array or tuple, so expand all to arrays
######
function ordering(df::AbstractDataFrame, cols::AbstractVector, lt, by, rev, order)
    to_array(src::AbstractVector, dims) = src
    to_array(src::Tuple, dims) = [src...]
    to_array(src, dims) = fill(src, dims)

    dims = length(cols) > 0 ? length(cols) : size(df,2)
    ordering(df, cols, 
             to_array(lt, dims),
             to_array(by, dims),
             to_array(rev, dims),
             to_array(order, dims))
end

#### Convert cols from tuple to Array, if necessary
ordering(df::AbstractDataFrame, cols::Tuple, args...) = ordering(df, [cols...], args...)


###########################
# Default sorting algorithm
###########################

# TimSort is fast for data with structure, but only if the DataFrame is large enough
# TODO: 8192 is informed but somewhat arbitrary

defalg(df::AbstractDataFrame) = size(df, 1) < 8192 ? Sort.MergeSort : SortingAlgorithms.TimSort

# For DataFrames, we can choose the algorithm based on the column type and requested ordering
function defalg{T<:Real}(df::AbstractDataFrame, ::Type{T}, o::Ordering)
    # If we're sorting a single numerical column in forward or reverse, 
    # RadixSort will generally be the fastest stable sort
    if isbits(T) && sizeof(T) <= 8 && (o==Order.Forward || o==Order.Reverse)
        SortingAlgorithms.RadixSort
    else
        defalg(df)
    end
end
defalg(df::AbstractDataFrame,        ::Type,          o::Ordering) = defalg(df)
defalg(df::AbstractDataFrame, col    ::ColumnIndex,   o::Ordering) = defalg(df, eltype(df[col]), o)
defalg(df::AbstractDataFrame, col_ord::UserColOrdering, o::Ordering) = defalg(df, col_ord.col, o)
defalg(df::AbstractDataFrame, cols,                   o::Ordering) = defalg(df)

function defalg(df::AbstractDataFrame, o::Ordering; alg=nothing, cols=[])
    alg != nothing && return alg
    defalg(df, cols, o)
end

########################
## Actual sort functions
########################

issorted(df::AbstractDataFrame; cols={}, lt=isless, by=identity, rev=false, order=Forward) = 
    issorted(EachRow(df), ordering(df, cols, lt, by, rev, order))

# sort!, sort, and sortperm functions

for s in {:sort!, :sort, :sortperm}
    @eval begin
        function $s(df::AbstractDataFrame; cols={}, alg=nothing,
                    lt=isless, by=identity, rev=false, order=Forward)
            ord = ordering(df, cols, lt, by, rev, order)
            _alg = defalg(df, ord; alg=alg, cols=cols)
            $s(df, _alg, ord)
        end
    end
end

function Base.sort!(df::AbstractDataFrame, a::Base.Sort.Algorithm, o::Base.Sort.Ordering)
    p = sortperm(df, a, o)
    pp = similar(p)
    for col in df.columns
        copy!(pp,p)
        Base.permute!!(col, pp)
    end
    df
end

sort    (df::AbstractDataFrame, a::Algorithm, o::Ordering) = df[sortperm(df, a, o),:]
sortperm(df::AbstractDataFrame, a::Algorithm, o::Union(Perm,DFPerm)) = sort!([1:nrow(df)], a, o)
sortperm(df::AbstractDataFrame, a::Algorithm, o::Ordering) = sortperm(df, a, DFPerm(o,df))

# Extras to speed up sorting
sortperm{V}(d::AbstractDataFrame, a::Algorithm, o::FastPerm{Sort.ForwardOrdering,V}) = sortperm(o.vec)
sortperm{V}(d::AbstractDataFrame, a::Algorithm, o::FastPerm{Sort.ReverseOrdering,V}) = reverse(sortperm(o.vec))

## Deprecated; remove after julia v0.3 is released (or sooner)

typealias ColIndexVec Union(AbstractVector{Integer}, AbstractVector{ASCIIString}, AbstractVector{UTF8String}, AbstractVector{Symbol})

@deprecate sort!(df::AbstractDataFrame, o::Ordering)  sort!(df,order=o)
@deprecate sort(df::AbstractDataFrame, o::Ordering)  sort(df,order=o)
@deprecate sortperm(df::AbstractDataFrame, o::Ordering)  sortperm(df, order=o)

@deprecate sortby!(df::AbstractDataFrame, by::Function)  sort!(df,by=by)

@deprecate sortby!(df::AbstractDataFrame, col ::ColumnIndex, o::Ordering)  sort!(df,cols=col,order=o)
@deprecate sortby!(df::AbstractDataFrame, col ::ColumnIndex)               sort!(df,cols=col)
@deprecate sortby!(df::AbstractDataFrame, cols::ColIndexVec, o::Ordering)  sort!(df,cols=cols,order=o)
@deprecate sortby!(df::AbstractDataFrame, cols::ColIndexVec)               sort!(df,cols=cols)
@deprecate sortby(df::AbstractDataFrame, col ::ColumnIndex, o::Ordering)  sort(df,cols=col,order=o)
@deprecate sortby(df::AbstractDataFrame, col ::ColumnIndex)               sort(df,cols=col)
@deprecate sortby(df::AbstractDataFrame, cols::ColIndexVec, o::Ordering)  sort(df,cols=cols,order=o)
@deprecate sortby(df::AbstractDataFrame, cols::ColIndexVec)               sort(df,cols=cols)

#@deprecate sort!   {O<:Ordering}(df::AbstractDataFrame, ::Type{O})    sort!   (df, order=O())
#@deprecate sort    {O<:Ordering}(df::AbstractDataFrame, ::Type{O})    sort    (df, order=O())
#@deprecate sortperm{O<:Ordering}(df::AbstractDataFrame, ::Type{O})    sortperm(df, order=O())

#@deprecate sortby!{O<:Ordering}(df::AbstractDataFrame, col::ColumnIndex, ::Type{O})                   sort!(df,col=col,order=O())
#@deprecate sortby!{O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, ::Type{O})                  sort!(df,cols=cols,order=O())
#@deprecate sortby!{O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{O})        sort!(df,DFPerm(o, df[cols]))
#@deprecate sortby {O<:Ordering}(df::AbstractDataFrame, col::ColumnIndex, ::Type{O})                   sort (df,col=col,order=O())
#@deprecate sortby {O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, ::Type{O})                  sort (df,cols=cols,order=O())
#@deprecate sortby {O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{O})        sort (df,DFPerm(o, df[cols]))

#@deprecate sortby!             (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{DataType}) sort!(df,DFPerm(Ordering[O() for O in o], df[cols]))
#           sortby!             (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray)           sortby!(df,cols,DataType[ot for ot in o])
#           sortby!             (df::AbstractDataFrame, col_ord::AbstractArray{Tuple}) = ((cols,o) = zip(col_ord...); sortby!(df, [cols...], [o...]))
#@deprecate sortby              (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{DataType}) sort (df,DFPerm(Ordering[O() for O in o], df[cols]))
#           sortby              (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray)           sortby!(df,cols,DataType[ot for ot in o])
#           sortby              (df::AbstractDataFrame, col_ord::AbstractArray{Tuple}) = ((cols,o) = zip(col_ord...); sortby!(df, [cols...], [o...]))

# reorder! for factors by specifying a DataFrame
function DataArrays.reorder(fun::Function, x::PooledDataArray, df::AbstractDataFrame)
    dfc = copy(df)
    dfc["__key__"] = x
    gd = by(dfc, "__key__", df -> colwise(fun, without(df, "__key__")))
    idx = sortperm(gd[[2:ncol(gd)]])
    return PooledDataArray(x, removeNA(gd[idx,1]))
end
DataArrays.reorder(x::PooledDataArray, df::AbstractDataFrame) = reorder(:mean, x, df)

DataArrays.reorder(fun::Function, x::PooledDataArray, y::AbstractVector...) =
    reorder(fun, x, DataFrame({y...}))


##############################################################################
##
## Iteration: EachRow, EachCol
##
##############################################################################

# Iteration by rows
type DFRowIterator
    df::AbstractDataFrame
end
EachRow(df::AbstractDataFrame) = DFRowIterator(df)
Base.start(itr::DFRowIterator) = 1
Base.done(itr::DFRowIterator, i::Int) = i > nrow(itr.df)
Base.next(itr::DFRowIterator, i::Int) = (itr.df[i, :], i + 1)
Base.size(itr::DFRowIterator) = (nrow(itr.df), )
Base.length(itr::DFRowIterator) = nrow(itr.df)
Base.getindex(itr::DFRowIterator, i::Any) = itr.df[i, :]
Base.map(f::Function, dfri::DFRowIterator) = [f(row) for row in dfri]


# Iteration by columns
type DFColumnIterator
    df::AbstractDataFrame
end
EachCol(df::AbstractDataFrame) = DFColumnIterator(df)
Base.start(itr::DFColumnIterator) = 1
Base.done(itr::DFColumnIterator, j::Int) = j > ncol(itr.df)
Base.next(itr::DFColumnIterator, j::Int) = (itr.df[:, j], j + 1)
Base.size(itr::DFColumnIterator) = (ncol(itr.df), )
Base.length(itr::DFColumnIterator) = ncol(itr.df)
Base.getindex(itr::DFColumnIterator, j::Any) = itr.df[:, j]
function Base.map(f::Function, dfci::DFColumnIterator)
    # note: `f` must return a consistent length
    res = DataFrame()
    for i = 1:ncol(dfci.df)
        res[i] = f(dfci[i])
    end
    colnames!(res, colnames(dfci.df))
    res
end
        

# Iteration matches that of Associative types (experimental)
Base.start(df::AbstractDataFrame) = 1
Base.done(df::AbstractDataFrame, i) = i > ncol(df)
Base.next(df::AbstractDataFrame, i) = ((colnames(df)[i], df[i]), i + 1)


##############################################################################
##
## Hashing
##
## Make sure this agrees with is_equals()
##
##############################################################################

function Base.hash(a::AbstractDataFrame)
    h = hash(size(a)) + 1
    for i in 1:ncol(a)
        h = bitmix(h, int(hash(a[i])))
    end
    return uint(h)
end

##############################################################################
##
## Dict conversion
##
## Try to insure this invertible.
## Allow option to flatten a single row.
##
##############################################################################

function dict(adf::AbstractDataFrame, flatten::Bool)
    # TODO: Make flatten an option
    # TODO: Provide a de-data option that makes Vector's, not
    #       DataVector's
    res = Dict{UTF8String, Any}()
    if flatten && nrow(adf) == 1
        for colname in colnames(adf)
            res[colname] = adf[colname][1]
        end
    else
        for colname in colnames(adf)
            res[colname] = adf[colname]
        end
    end
    return res
end
dict(adf::AbstractDataFrame) = dict(adf, false)

# TODO: Add proper tests
# adf = DataFrame(quote A = 1:4; B = ["A", "B", "C", "D"] end)
# DataFrames.dict(adf)
# ["B"=>["A", "B", "C", "D"],"A"=>[1, 2, 3, 4]]
# DataFrames.dict(adf[1, :])
# ["B"=>["A"],"A"=>[1]]
# DataFrames.dict(adf[1, :], true)
# ["B"=>"A","A"=>1]

# Pooling

pool(a::AbstractVector) = compact(PooledDataArray(a))

function pool!(df::AbstractDataFrame, cname::Union(Integer, String))
    df[cname] = pool(df[cname])
    return
end

function pool!{T <: Union(Integer, String)}(df::AbstractDataFrame, cnames::Vector{T})
    for cname in cnames
        df[cname] = pool(df[cname])
    end
    return
end

function pool!(df)
    for i in 1:size(df, 2)
        if eltype(df[i]) <: String
            df[i] = pool(df[i])
        end
    end
    return
end
