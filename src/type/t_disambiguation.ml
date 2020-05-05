(*
 * type/disambiguation.ml --- sort expressions
 *
 *
 * Copyright (C) 2008-2010  INRIA and Microsoft Corporation
 *)

open Ext
open Expr.T
open Property
open Util

open T_t

module B = Builtin


(* {3 Annotations} *)

(* FIXME remove *)
let any_special_prop = make "Type.Disambiguation.any_special_prop"
(* FIXME remove *)
let cast_special_prop = make "Type.Disambiguation.cast_special_prop"
(* FIXME remove *)
let int_special_prop = make "Type.Disambiguation.int_special_prop"
(* FIXME remove *)
let real_special_prop = make "Type.Disambiguation.real_special_prop"

let as_prop = make "Type.Disambiguation.as_prop"


(* {3 Symbols} *)

let tla_prefix = "TLA__"

(* FIXME remove *)
let cast_nm s1 s2 = "?"

let any_nm s =
  match s with
  | TU    -> tla_prefix ^ "any_u"
  | TBool -> tla_prefix ^ "any_bool"
  | TInt  -> tla_prefix ^ "any_int"
  | TReal -> tla_prefix ^ "any_real"
  | TStr  -> tla_prefix ^ "any_string"


(* {3 Utils} *)

let from_shp = function
  | Shape_expr -> mk_cstk_ty ty_u
  | Shape_op n -> mk_fstk_ty (List.init n (fun _ -> ty_u)) ty_u

let mk_kind srts srt =
  mk_fstk_ty (List.map mk_atom_ty srts) (mk_atom_ty srt)

let mk_eq a e1 e2 =
  let op = assign (Internal B.Eq %% []) Props.kind_prop (mk_kind [a; a] TBool) in
  Apply (op, [ e1 ; e2 ]) %% []

let proj_bool = function
  | TBool -> fun e -> e
  | a ->
      let any = assign (Opaque (any_nm a) %% []) Props.kind_prop (mk_kind [] a) in
      fun e -> mk_eq a e any

let cast a e =
  assign e as_prop a

let cast_to_set = function
  | TU -> fun e -> e
  | _ -> fun e -> cast TU e


(* {3 Contexts} *)

(** Overriding {!Type.T.ty}. We only want basic sorts and
    operator kinds here.
*)
type ty =
  | Sort of ty_atom
  | Kind of ty_kind
  | Unknown

type cx = ty Ctx.t

let adj cx v ty =
  let v =
    match ty with
    | Sort a  -> assign v Props.atom_prop a
    | Kind k  -> assign v Props.kind_prop k
    | Unknown -> assign v Props.type_prop TUnknown
  in
  (v, Ctx.adj cx v.core ty)

let adjs cx vs tys =
  let vs, cx = List.fold_left begin fun (vs, cx) (v, ty) ->
    let v, cx = adj cx v ty in
    (v :: vs, cx)
  end ([], cx) (List.combine vs tys) in
  (List.rev vs, cx)

let bump cx = snd (adj cx ("" %% []) Unknown)

let lookup_ty cx n =
  let _, ty = Ctx.index cx n in
  Option.default Unknown ty

let lookup_srt cx n =
  match lookup_ty cx n with
  (* Some sorts are put into the context as a constant kind.
   * e.g. ASSUME NEW x PROVE .. *)
  | Sort a | Kind (TKind ([], TAtom a)) -> a
  | _ -> invalid_arg "Type.Disambiguation.lookup_srt: not a sort"

let lookup_kind cx n =
  match lookup_ty cx n with
  | Kind k -> k
  | _ -> invalid_arg "Type.Disambiguation.lookup_kind: not a kind"


(* {3 Main} *)

(** Annotations are placed here:
      - Bound variables in Quant, Tquant, Choose, SetSt, SetOf, Fcn;
      - Variables of Fresh, Flex;
      - Defined operators in Defn-Operator.

    The algorithm method is implemented as a foldmap on the whole
    datastructure.  We give a summary of the main methods here:
      - [expr] and [lexpr] expect a regular expression; the first one
        returns a sort, and the second one a kind;
      - [bound] and [bounds] return "Unknown", but the returned bound(s)
        are annotated with [U];
      - [hyp] and [hyps] return "Unknown", but the returned hyp(s) is
        annotated with the correct kind if it is a declaration; temporal
        variables get a sort;
      - [defn] returns "Unknown";
      - [sequent] returns the sort "bool".
*)

let rec expr scx oe =
  match oe.core with
  | Ix n ->
      let srt = lookup_srt scx n in
      Ix n @@ oe, srt

  (* NOTE Particular cases for builtins treated here to handle overloaded ops. *)
  (* Arithmetic operators are replaced by a specialized version if possible. *)
  (* TODO int to real casts *)
  | Internal (B.TRUE | B.FALSE) as op ->
      op @@ oe, TBool

  | Apply ({ core = Internal (B.Implies | B.Equiv | B.Conj | B.Disj) } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      Apply (op, [ proj_bool srt1 e ; proj_bool srt2 f ]) @@ oe, TBool

  | Apply ({ core = Internal B.Neg } as op, [ e ]) ->
      let e, srt = expr scx e in
      Apply (op, [ proj_bool srt e ]) @@ oe, TBool

  | Apply ({ core = Internal (B.Eq | B.Neq) } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      if srt1 = srt2 then
        let srt = srt1 in
        let op = assign op Props.kind_prop (mk_kind [ srt ; srt ] TBool) in
        Apply (op, [ e ; f ]) @@ oe, TBool
      else
        let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TBool) in
        Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TBool

  | Internal (B.STRING | B.BOOLEAN | B.Nat | B.Int | B.Real) as op ->
      op @@ oe, TU

  | Apply ({ core = Internal (B.SUBSET | B.UNION | B.DOMAIN) } as op, [ e ]) ->
      let e, srt = expr scx e in
      let op = assign op Props.kind_prop (mk_kind [ TU ] TU) in
      Apply (op, [ cast_to_set srt e ]) @@ oe, TU

  | Apply ({ core = Internal (B.Subseteq | B.Mem | B.Notmem) } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TBool) in
      Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TBool

  | Apply ({ core = Internal (B.Setminus | B.Cap | B.Cup) } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TU) in
      Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TU

  | Apply ({ core = Internal (B.Plus | B.Minus | B.Times | B.Quotient | B.Remainder | B.Exp) } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      if srt1 = TInt && srt2 = TInt then
        let op = assign op Props.kind_prop (mk_kind [ TInt ; TInt ] TInt) in
        Apply (op, [ e ; f ]) @@ oe, TInt
      else if srt1 = TReal && srt2 = TReal then
        let op = assign op Props.kind_prop (mk_kind [ TReal ; TReal ] TReal) in
        Apply (op, [ e ; f ]) @@ oe, TReal
      else
        let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TU) in
        Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TU

  | Apply ({ core = Internal B.Ratio } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      if srt1 = TReal && srt2 = TReal then
        let op = assign op Props.kind_prop (mk_kind [ TReal ; TReal ] TReal) in
        Apply (op, [ e ; f ]) @@ oe, TReal
      else
        let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TU) in
        Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TU

  | Apply ({ core = Internal B.Uminus } as op, [ e ; f ]) ->
      let e, srt = expr scx e in
      if srt = TInt then
        let op = assign op Props.kind_prop (mk_kind [ TInt ] TInt) in
        Apply (op, [ e ]) @@ oe, TInt
      else if srt = TReal then
        let op = assign op Props.kind_prop (mk_kind [ TReal ] TReal) in
        Apply (op, [ e ]) @@ oe, TReal
      else
        let op = assign op Props.kind_prop (mk_kind [ TU ] TU) in
        Apply (op, [ cast_to_set srt e ]) @@ oe, TU

  | Internal B.Infinity as op ->
      op @@ oe, TReal

  | Apply ({ core = Internal (B.Lteq | B.Lt | B.Gteq | B.Gt) } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      if srt1 = TInt && srt2 = TInt then
        let op = assign op Props.kind_prop (mk_kind [ TInt ; TInt ] TBool) in
        Apply (op, [ e ; f ]) @@ oe, TBool
      else if srt1 = TReal && srt2 = TReal then
        let op = assign op Props.kind_prop (mk_kind [ TReal ; TReal ] TBool) in
        Apply (op, [ e ; f ]) @@ oe, TBool
      else
        let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TBool) in
        Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TBool

  | Apply ({ core = Internal B.Range } as op, [ e ; f ]) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      if srt1 = TInt && srt2 = TInt then
        let op = assign op Props.kind_prop (mk_kind [ TInt ; TInt ] TU) in
        Apply (op, [ e ; f ]) @@ oe, TU
      else if srt1 = TReal && srt2 = TReal then
        let op = assign op Props.kind_prop (mk_kind [ TReal ; TReal ] TU) in
        Apply (op, [ e ; f ]) @@ oe, TU
      else
        let op = assign op Props.kind_prop (mk_kind [ TU ; TU ] TU) in
        Apply (op, [ cast_to_set srt1 e ; cast_to_set srt2 f ]) @@ oe, TU
  (* NOTE Case by case ends here *)

  | Apply (op, args) ->
      let op, (TKind (ks, ty)) = lexpr scx op in
      let args =
        List.map2 begin fun arg (TKind (ks, ty)) ->
          match ks, get_atom ty with
          | [], TU ->
              let arg, srt = expr scx arg in
              cast_to_set srt arg
          | [], TBool ->
              let arg, srt = expr scx arg in
              proj_bool srt arg
          | _, _ ->
              let arg, k = lexpr scx arg in
              if k = TKind (ks, ty) then
                arg
              else
                invalid_arg "Type.Disambiguation.expr: bad operator argument"
        end args ks
      in
      Apply (op, args) @@ oe, get_atom ty

  | Internal _ ->
      Errors.bug ~at:oe "Type.Disambiguation.expr: Encounter Internal"
  | Lambda _ ->
      Errors.bug ~at:oe "Type.Disambiguation.expr: Encounter Lambda"
  | Bang _ ->
      Errors.bug ~at:oe "Type.Disambiguation.expr: Encounter Bang"
  | Opaque s ->
      (* FIXME primed variables may occur as opaques here *)
      (* This is very annoying *)
      Errors.bug ~at:oe ("Type.Disambiguation.expr: Encounter Opaque '" ^ s ^ "'")
  | At _ ->
      Errors.bug ~at:oe "Type.Disambiguation.expr: Encounter At"

  | Sequent sq ->
      let _, sq, _ = sequent scx sq in
      Sequent sq @@ oe, TBool

  | With (e, m) ->
      let e, srt = expr scx e in
      With (e, m) @@ oe, srt

  | If (e, f, g) ->
      let e, srt1 = expr scx e in
      let f, srt2 = expr scx f in
      let g, srt3 = expr scx g in
      (* If f and g have the same sort, the if-expression has that sort;
       * otherwise f and g are coerced to [U]. *)
      if srt2 = srt3 then
        If (proj_bool srt1 e, f, g) @@ oe, srt2
      else
        If (proj_bool srt1 e, cast_to_set srt2 f, cast_to_set srt3 f) @@ oe, TU

  | List (bl, es) ->
      let es = List.map begin fun e ->
        let e, srt = expr scx e in
        proj_bool srt e
      end es in
      List (bl, es) @@ oe, TBool

  | Let (ds, e) ->
      let scx, ds, _ = defns scx ds in
      let e, srt = expr scx e in
      Let (ds, e) @@ oe, srt

  | Quant (q, bs, e) ->
      let scx, bs, _ = bounds scx bs in
      let e, srt = expr scx e in
      Quant (q, bs, proj_bool srt e) @@ oe, TBool

  | Tquant (q, hs, e) ->
      let scx, hs = List.fold_left begin fun (scx, hs) h ->
        let h1, scx = adj scx h (Sort TU) in
        let h2, scx = adj scx h (Sort TU) in
        scx, h2 :: h1 :: hs
      end (scx, []) hs in
      let hs = List.rev hs in
      let e, srt = expr scx e in
      Tquant (q, hs, proj_bool srt e) @@ oe, TBool

  | Choose (h, hdom, e) ->
      let hdom =
        match hdom with
        | None -> None
        | Some dom ->
            let dom, srt = expr scx dom in
            Some (cast_to_set srt dom)
      in
      let h, scx = adj scx h (Sort TU) in
      let e, srt = expr scx e in
      Choose (h, hdom, proj_bool srt e) @@ oe, TU

  | SetSt (h, e1, e2) ->
      let e1, srt1 = expr scx e1 in
      let h, scx = adj scx h (Sort TU) in
      let e2, srt2 = expr scx e2 in
      SetSt (h, cast_to_set srt1 e1, proj_bool srt2 e2) @@ oe, TU

  | SetOf (e, bs) ->
      let scx, bs, _ = bounds scx bs in
      let e, srt = expr scx e in
      SetOf (cast_to_set srt e, bs) @@ oe, TU

  | SetEnum es ->
      let es = List.map begin fun e ->
        let e, srt = expr scx e in
        cast_to_set srt e
      end es in
      SetEnum es @@ oe, TU

  | Product es ->
      let es = List.map begin fun e ->
        let e, srt = expr scx e in
        cast_to_set srt e
      end es in
      Product es @@ oe, TU

  | Tuple es ->
      let es = List.map begin fun e ->
        let e, srt = expr scx e in
        cast_to_set srt e
      end es in
      Tuple es @@ oe, TU

  | Fcn (bs, e) ->
      let scx, bs, _ = bounds scx bs in
      let e, srt = expr scx e in
      Fcn (bs, cast_to_set srt e) @@ oe, TU

  | FcnApp (e, es) ->
      let e, srt = expr scx e in
      let es = List.map begin fun e ->
        let e, srt = expr scx e in
        cast_to_set srt e
      end es in
      FcnApp (cast_to_set srt e, es) @@ oe, TU

  | Arrow (e1, e2) ->
      let e1, srt1 = expr scx e1 in
      let e2, srt2 = expr scx e2 in
      Arrow (cast_to_set srt1 e1, cast_to_set srt2 e2) @@ oe, TU

  | Rect fs ->
      let fs = List.map begin fun (f, e) ->
        let e, srt = expr scx e in
        (f, cast_to_set srt e)
      end fs in
      Rect fs @@ oe, TU

  | Record fs ->
      let fs = List.map begin fun (f, e) ->
        let e, srt = expr scx e in
        (f, cast_to_set srt e)
      end fs in
      Record fs @@ oe, TU

  | Except (e, exs) ->
      let exs, _ = List.map (exspec scx) exs |> List.split in
      let e, srt = expr scx e in
      Except (cast_to_set srt e, exs) @@ oe, TU

  | Dot (e, s) ->
      let e, srt = expr scx e in
      Dot (cast_to_set srt e, s) @@ oe, TU

  | Sub (m, e1, e2) ->
      let e1, srt1 = expr scx e1 in
      let e2, srt2 = expr scx e2 in
      Sub (m, cast_to_set srt1 e1, cast_to_set srt2 e2) @@ oe, TBool

  | Tsub (m, e1, e2) ->
      let e1, srt1 = expr scx e1 in
      let e2, srt2 = expr scx e2 in
      Tsub (m, cast_to_set srt1 e1, cast_to_set srt2 e2) @@ oe, TBool

  | Fair (f, e1, e2) ->
      let e1, srt1 = expr scx e1 in
      let e2, srt2 = expr scx e2 in
      Fair (f, cast_to_set srt1 e1, cast_to_set srt2 e2) @@ oe, TBool

  | Case (ps, o) ->
      let ps, tys =
        List.map begin fun (p, e) ->
          let p, srt1 = expr scx p in
          let e, srt2 = expr scx e in
          (proj_bool srt1 p, e), srt2
        end ps
        |> List.split
      in
      let o, o_ty =
        match o with
        | None -> None, None
        | Some e ->
            let e, srt = expr scx e in
            Some e, Some srt
      in
      (* Like for if-expressions, the branches are coerced to [set]
       * if their types differ. All types must be computed first. *)
      let ps, o, srt =
        let tty = List.hd tys in
        let ttys =
          match o_ty with
          | None -> List.tl tys
          | Some srt -> srt :: List.tl tys
        in
        if List.for_all ((=) tty) ttys then
          ps, o, tty
        else
          let ps = List.map2 begin fun (p, e) srt ->
            (p, cast_to_set srt e)
          end ps tys in
          let o = Option.map begin fun e ->
            let srt = Option.get o_ty in
            cast_to_set srt e
          end o in
          ps, o, TU
      in
      Case (ps, o) @@ oe, srt

  | String s ->
      String s @@ oe, TStr
  | Num (m, "") ->
      Num (m, "") @@ oe, TInt
  | Num (m, n) ->
      Num (m, n) @@ oe, TReal

  | Parens (e, pf) ->
      let e, srt = expr scx e in
      Parens (e, pf) @@ oe, srt

and lexpr scx loe =
  match loe.core with
  | Ix n ->
      let k = lookup_kind scx n in
      assign (Ix n @@ loe) Props.kind_prop k, k
  | Lambda (vs, e) ->
      let scx, vs, ks =
        List.fold_left begin fun (scx, vs, ks) (h, shp) ->
          let k = from_shp shp in
          let h, scx = adj scx h (Kind k) in
          let v = (h, shp) in
          (scx, v :: vs, k :: ks)
        end (scx, [], []) vs
      in
      let ks = List.rev ks in
      let vs = List.rev vs in
      let e, srt = expr scx e in
      let k = mk_kind_ty ks (mk_atom_ty srt) in
      assign (Lambda (vs, e) @@ loe) Props.kind_prop k, k
  | _ -> Errors.bug ~at:loe "Type.Disambiguation.lexpr"

and sequent scx sq =
  let scx, hs, _ = hyps scx sq.context in
  let g, srt = expr scx sq.active in
  scx, { context = hs ; active = proj_bool srt g }, TBool

and exspec scx (exps, e) =
  let exps = List.map begin function
    | Except_dot s -> Except_dot s
    | Except_apply e ->
        let e, srt = expr scx e in
        Except_apply (cast_to_set srt e)
  end exps in
  let e, srt = expr scx e in
  (exps, cast_to_set srt e), Unknown

and bounds scx bs =
  let scx, bs =
    List.fold_left begin fun (scx', bs) (h, k, dom) ->
      (* [scx'] has a prime because bound domains must be evaluated
       * in the upper context [scx]. *)
      let dom =
        match dom with
        | Domain d ->
            let d, srt = expr scx d in
            Domain (cast_to_set srt d)
        | _ -> dom
      in
      let h, scx' = adj scx' h (Sort TU) in
      let b = (h, k, dom) in
      (scx', b :: bs)
    end (scx, []) bs
  in
  let bs = List.rev bs in
  scx, bs, Unknown

and bound scx b =
  match bounds scx [b] with
  | scx, [b], _ -> scx, b, Unknown
  | _, _, _ -> assert false

and defn scx df =
  match df.core with
  | Recursive (h, shp) ->
      let k = from_shp shp in
      let h, scx = adj scx h (Kind k) in
      scx, Recursive (h, shp) @@ df, Unknown
  | Operator (h, ({ core = Lambda (vs, e) } as oe)) ->
      let scx', vs, ks =
        List.fold_left begin fun (scx, vs, ks) (h, shp) ->
          let k = from_shp shp in
          let h, scx = adj scx h (Kind k) in
          let v = (h, shp) in
          (scx, v :: vs, k :: ks)
        end (scx, [], []) vs
      in
      let ks = List.rev ks in
      let vs = List.rev vs in
      let e, srt = expr scx' e in
      let h, scx = adj scx h (Kind (mk_kind_ty ks (mk_atom_ty srt))) in
      scx, Operator (h, Lambda (vs, e) @@ oe) @@ df, Unknown
  | Operator (h, e) ->
      let e, srt = expr scx e in
      (* Annotated as a constant kind for consistency reasons *)
      let h, scx = adj scx h (Kind (mk_cstk_ty (mk_atom_ty srt))) in
      scx, Operator (h, e) @@ df, Unknown
  | Instance (h, i) ->
      Errors.bug ~at:df "Type.Disambiguation.defn"
  | Bpragma (h, e, args) ->
      let e, srt = expr scx e in
      let h, scx = adj scx h (Sort srt) in
      scx, Bpragma (h, e, args) @@ df, Unknown

and defns scx dfs =
  match dfs with
  | [] -> scx, [], Unknown
  | df :: dfs ->
      let scx, df, _ = defn scx df in
      let scx, dfs, _ = defns scx dfs in
      scx, df :: dfs, Unknown

and hyp scx h =
  match h.core with
  | Fresh (v, shp, kd, hdom) ->
      let hdom =
        match hdom with
        | Unbounded -> Unbounded
        | Bounded (dom, vis) ->
            let dom, srt = expr scx dom in
            Bounded (cast_to_set srt dom, vis)
      in
      let k = from_shp shp in
      let v, scx = adj scx v (Kind k) in
      let h = Fresh (v, shp, kd, hdom) @@ h in
      scx, h, Unknown
  | Flex v ->
      let v, scx = adj scx v (Kind (mk_cstk_ty ty_u)) in
      let v_p = (v.core ^ "__prime") @@ v in
      let _, scx = adj scx v_p (Kind (mk_cstk_ty ty_u)) in
      let h = Flex v @@ h in
      scx, h, Unknown
  | Defn (df, wd, vis, ex) ->
      let scx, df, _ = defn scx df in
      let h = Defn (df, wd, vis, ex) @@ h in
      scx, h, Unknown
  | Fact (e, vis, tm) ->
      let e, srt = expr scx e in
      let e = proj_bool srt e in
      let scx = bump scx in
      let h = Fact (e, vis, tm) @@ h in
      scx, h, Unknown

and hyps scx hs =
  match Deque.front hs with
  | None -> scx, Deque.empty, Unknown
  | Some (h, hs) ->
      let scx, h, _ = hyp scx h in
      let scx, hs, _ = hyps scx hs in
      scx, Deque.cons h hs, Unknown

let min_reconstruct sq =
  let scx = Ctx.dot in
  let _, sq, _ = sequent scx sq in
  sq
