
# Here we override broadcasting for banded matrices.
# The design is to to exploit the broadcast machinery so that
# banded matrices that conform to the banded matrix interface but are not
# <: AbstractBandedMatrix can get access to fast copyto!, lmul!, rmul!, axpy!, etc.
# using broadcast variants (B .= A, B .= 2.0 .* A, etc.)


abstract type AbstractBlockStyle{N} <: AbstractArrayStyle{N} end
struct BlockStyle{N} <: AbstractBlockStyle{N} end
struct PseudoBlockStyle{N} <: AbstractBlockStyle{N} end


BlockStyle(::Val{N}) where {N} = BlockStyle{N}()
PseudoBlockStyle(::Val{N}) where {N} = PseudoBlockStyle{N}()
BlockStyle{M}(::Val{N}) where {N,M} = BlockStyle{N}()
PseudoBlockStyle{M}(::Val{N}) where {N,M} = PseudoBlockStyle{N}()
blockbroadcaststyle(::AbstractArrayStyle{N}) where N = BlockStyle{N}()
pseudoblockbroadcaststyle(::AbstractArrayStyle{N}) where N = PseudoBlockStyle{N}()
BroadcastStyle(::Type{<:BlockArray{<:Any,N,Arr}}) where {N,Arr} = blockbroadcaststyle(BroadcastStyle(Arr))
BroadcastStyle(::Type{<:PseudoBlockArray{<:Any,N,Arr}}) where {N,Arr} = pseudoblockbroadcaststyle(BroadcastStyle(Arr))
BroadcastStyle(::DefaultArrayStyle{N}, b::AbstractBlockStyle{M}) where {M,N} = typeof(b)(Val(max(M,N)))
BroadcastStyle(a::AbstractBlockStyle{N}, ::DefaultArrayStyle{M}) where {M,N} = typeof(a)(Val(max(M,N)))
BroadcastStyle(::StructuredMatrixStyle, b::AbstractBlockStyle{M}) where {M} = typeof(b)(Val(max(M,2)))
BroadcastStyle(a::AbstractBlockStyle{M}, ::StructuredMatrixStyle) where {M} = typeof(a)(Val(max(M,2)))
BroadcastStyle(::BlockStyle{M}, ::PseudoBlockStyle{N}) where {M,N} = BlockStyle(Val(max(M,N)))
BroadcastStyle(::PseudoBlockStyle{M}, ::BlockStyle{N}) where {M,N} = BlockStyle(Val(max(M,N)))


# sortedunion can assume inputs are already sorted so this could be improved
sortedunion(a,b) = sort!(union(a,b))
sortedunion(a::Base.OneTo, b::Base.OneTo) = Base.OneTo(max(last(a),last(b)))
sortedunion(a::AbstractUnitRange, b::AbstractUnitRange) = min(first(a),first(b)):max(last(a),last(b))
combine_blockaxes(a, b) = _BlockedUnitRange(sortedunion(blocklasts(a), blocklasts(b)))

Base.Broadcast.axistype(a::T, b::T) where T<:BlockedUnitRange = length(b) == 1 ? a : combine_blockaxes(a, b)
Base.Broadcast.axistype(a::BlockedUnitRange, b::BlockedUnitRange) = length(b) == 1 ? a : combine_blockaxes(a, b)
Base.Broadcast.axistype(a::BlockedUnitRange, b) = length(b) == 1 ? a : combine_blockaxes(a, b)
Base.Broadcast.axistype(a, b::BlockedUnitRange) = length(b) == 1 ? a : combine_blockaxes(a, b)


similar(bc::Broadcasted{<:AbstractBlockStyle{N}}, ::Type{T}) where {T,N} =
    BlockArray{T,N}(undef, axes(bc))

similar(bc::Broadcasted{PseudoBlockStyle{N}}, ::Type{T}) where {T,N} =
    PseudoBlockArray{T,N}(undef, axes(bc))

"""
    SubBlockIterator(subblock_lasts::Vector{Int}, block_lasts::Vector{Int})
    SubBlockIterator(A::AbstractArray, bs::NTuple{N,AbstractUnitRange{Int}} where N, dim::Integer)

An iterator for iterating `BlockIndexRange` of the blocks specified by
`subblock_lasts`.  The `Block` index part of `BlockIndexRange` is
determined by `subblock_lasts`.  That is to say, the `Block` index first
specifies one of the block represented by `subblock_lasts` and then the
inner-block index range specifies the region within the block.  Each
such block corresponds to a block specified by `blocklasts`.

Note that the invariance `subblock_lasts ⊂ block_lasts` must hold and must
be ensured by the caller.

# Examples
```jldoctest
julia> using BlockArrays

julia> import BlockArrays: SubBlockIterator, BlockIndexRange

julia> A = BlockArray(1:6, 1:3);

julia> subblock_lasts = axes(A, 1).lasts;

julia> @assert subblock_lasts == [1, 3, 6];

julia> block_lasts = [1, 3, 4, 6];

julia> for idx in SubBlockIterator(subblock_lasts, block_lasts)
           B = @show view(A, idx)
           @assert !(parent(B) isa BlockArray)
           idx :: BlockIndexRange
           idx.block :: Block{1}
           idx.indices :: Tuple{UnitRange}
       end
view(A, idx) = [1]
view(A, idx) = [2, 3]
view(A, idx) = [4]
view(A, idx) = [5, 6]

julia> [idx.block.n[1] for idx in SubBlockIterator(subblock_lasts, block_lasts)]
4-element Array{Int64,1}:
 1
 2
 3
 3

julia> [idx.indices[1] for idx in SubBlockIterator(subblock_lasts, block_lasts)]
4-element Array{UnitRange{Int64},1}:
 1:1
 1:2
 1:1
 2:3
```
"""
struct SubBlockIterator
    subblock_lasts::Vector{Int}
    block_lasts::Vector{Int}
end

Base.IteratorEltype(::Type{<:SubBlockIterator}) = Base.HasEltype()
Base.eltype(::Type{<:SubBlockIterator}) = BlockIndexRange{1,Tuple{UnitRange{Int64}}}

Base.IteratorSize(::Type{<:SubBlockIterator}) = Base.HasLength()
Base.length(it::SubBlockIterator) = length(it.block_lasts)

SubBlockIterator(arr::AbstractArray, bs::NTuple{N,AbstractUnitRange{Int}}, dim::Integer) where N =
    SubBlockIterator(blocklasts(axes(arr, dim)), blocklasts(bs[dim]))

function Base.iterate(it::SubBlockIterator, state=nothing)
    if state === nothing
        i,j = 1,1
    else
        i, j = state
    end
    length(it.block_lasts)+1 == i && return nothing
    idx = i == 1 ? (1:it.block_lasts[i]) : (it.block_lasts[i-1]+1:it.block_lasts[i])

    bir = Block(j)[j == 1 ? idx : idx .- it.subblock_lasts[j-1]]
    if it.subblock_lasts[j] == it.block_lasts[i]
        j += 1
    end
    return (bir, (i + 1, j))
end

subblocks(::Any, bs::NTuple{N,AbstractUnitRange{Int}}, dim::Integer) where N =
    (nothing for _ in blockaxes(bs[dim], 1))

function subblocks(arr::AbstractArray, bs::NTuple{N,AbstractUnitRange{Int}}, dim::Integer) where N
    if size(arr, dim) == 1
        return (BlockIndexRange(Block(1), 1:1) for _ in blockaxes(bs[dim], 1))
    end
    return SubBlockIterator(arr, bs, dim)
end

@inline _bview(arg, ::Vararg) = arg
@inline _bview(A::AbstractArray, I...) = view(A, I...)

@inline function Base.Broadcast.materialize!(dest, bc::Broadcasted{BS}) where {Style,BS<:AbstractBlockStyle}
    return copyto!(dest, Base.Broadcast.instantiate(Base.Broadcast.Broadcasted{BS}(bc.f, bc.args, combine_blockaxes.(axes(dest),axes(bc)))))
end

@generated function copyto!(dest::AbstractArray,
                            bc::Broadcasted{<:AbstractBlockStyle{NDims}, <:Any, <:Any, Args}) where {NDims, Args <: Tuple}

    NArgs = length(Args.parameters)

    # `bvar(0, dim)` is a variable for BlockIndexRange of `dim`-th dimension
    # of `dest` array.  `bvar(i, dim)` is a similar variable of `i`-th
    # argument in `bc.args`.
    bvar(i, dim) = Symbol("blockindexrange_", i, "_", dim)

    function forloop(dim)
        if dim > 0
            quote
                for ($(bvar(0, dim)), $(bvar.(1:NArgs, dim)...),) in zip(
                        subblocks(dest, bs, $dim),
                        subblocks.(bc.args, Ref(bs), Ref($dim))...)
                    $(forloop(dim - 1))
                end
            end
        else
            bview(a, i) = :(_bview($a, $([bvar(i, d) for d in 1:NDims]...)))
            destview = bview(:dest, 0)
            argblocks = [bview(:(bc.args[$i]), i) for i in 1:NArgs]
            quote
                broadcast!(bc.f, $destview, $(argblocks...))
            end
        end
    end

    quote
        bs = axes(bc)
        if !blockisequal(axes(dest), bs)
            copyto!(PseudoBlockArray(dest, bs), bc)
            return dest
        end

        $(forloop(NDims))
        return dest
    end
end

@inline function Broadcast.instantiate(bc::Broadcasted{Style}) where {Style <:AbstractBlockStyle}
    bcf = Broadcast.instantiate(Broadcast.flatten(Broadcasted{Nothing}(bc.f, bc.args, bc.axes)))
    return Broadcasted{Style}(bcf.f, bcf.args, bcf.axes)
end


for op in (:+, :-, :*)
    @eval function copy(bc::Broadcasted{BlockStyle{N},<:Any,typeof($op),<:Tuple{<:AbstractArray{<:Number,N}}}) where N
        (A,) = bc.args
        _BlockArray(broadcast(a -> broadcast($op, a), blocks(A)), axes(A))
    end
end

for op in (:+, :-, :*, :/, :\)
    @eval begin
        function copy(bc::Broadcasted{BlockStyle{N},<:Any,typeof($op),<:Tuple{<:Number,<:AbstractArray{<:Number,N}}}) where N
            x,A = bc.args
            _BlockArray(broadcast((x,a) -> broadcast($op, x, a), x, blocks(A)), axes(A))
        end
        function copy(bc::Broadcasted{BlockStyle{N},<:Any,typeof($op),<:Tuple{<:AbstractArray{<:Number,N},<:Number}}) where N
            A,x = bc.args
            _BlockArray(broadcast((a,x) -> broadcast($op, a, x), blocks(A),x), axes(A))
        end
    end
end

# exploit special cases for *, for example, *(::Number, ::Diagonal)
for op in (:*, :/) 
    @eval @inline $op(A::BlockArray, x::Number) = _BlockArray($op(blocks(A),x), axes(A))
end
for op in (:*, :\)
    @eval @inline $op(x::Number, A::BlockArray) = _BlockArray($op(x,blocks(A)), axes(A))
end

###
# SubViews
###

_blocktype(::Type{<:BlockArray{<:Any,N,<:AbstractArray{R,N}}}) where {N,R} = R

BroadcastStyle(::Type{<:SubArray{T,N,Arr,<:NTuple{N,BlockSlice1},false}}) where {T,N,Arr<:BlockArray} = 
    BroadcastStyle(_blocktype(Arr))
BroadcastStyle(::Type{<:SubArray{T,N,Arr,<:NTuple{N,BlockSlice{BlockRange{1,Tuple{II}}}},false}}) where {T,N,Arr<:BlockArray,II} = 
    BroadcastStyle(Arr)