def add2 (a0, b0) (a1, b1) =
  (a0 i64.+ a1, b0 i64.+ b1)

def to_index offset (f, _) (o0, o1) =
  if f==1i64 then o0-1i64 else offset+o1-1
                           
-- | Partition implementation which has an added reduce allow for the
-- map-scan-map-scatter being fused like in filter. 
def partition' [n] 'a (p: a -> bool) (as: [n]a): [n]a =
  let flags = map (\x -> if p x then (1, 0) else (0, 1)) as
  let offset = map (.0) flags |> reduce_comm (+) 0
  let offsets = scan add2 (0, 0) flags
  let idxs = map2 (to_index offset) flags offsets
  in scatter (copy as)
             idxs
             as

-- ==
-- input @ ../../data/randomints_full_500MiB.in
-- output @ ../randomints_full_500MiB.out
-- input @ ../../data/randomints_dense_500MiB.in
-- output @ ../randomints_dense_500MiB.out
-- input @ ../../data/randomints_moderate_500MiB.in
-- output @ ../randomints_moderate_500MiB.out
-- input @ ../../data/randomints_sparse_500MiB.in
-- output @ ../randomints_sparse_500MiB.out
-- input @ ../../data/randomints_empty_500MiB.in
-- output @ ../randomints_empty_500MiB.out
entry main [n] (as: [n]i32): [n]i32 =
  partition' (0i32<) as

-- ==
-- entry: intscan
-- input @ ../../data/randomints_full_500MiB.in
-- input @ ../../data/randomints_dense_500MiB.in
-- input @ ../../data/randomints_moderate_500MiB.in
-- input @ ../../data/randomints_sparse_500MiB.in
-- input @ ../../data/randomints_empty_500MiB.in
entry intscan [n] (as: [n]i32): [n]i32 =
  scan (+) 0 as

-- ==
-- entry: expected
-- input @ ../../data/randomints_full_500MiB.in
-- output @ ../randomints_full_500MiB.out
-- input @ ../../data/randomints_dense_500MiB.in
-- output @ ../randomints_dense_500MiB.out
-- input @ ../../data/randomints_moderate_500MiB.in
-- output @ ../randomints_moderate_500MiB.out
-- input @ ../../data/randomints_sparse_500MiB.in
-- output @ ../randomints_sparse_500MiB.out
-- input @ ../../data/randomints_empty_500MiB.in
-- output @ ../randomints_empty_500MiB.out
entry expected [n] (as: [n]i32): [n]i32 =
  partition (0i32<) as
  |> uncurry (++)
  |> sized n