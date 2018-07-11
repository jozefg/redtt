open Val
open RedBasis.Bwd


module Env :
sig
  type t

  val len : t -> int

  val emp : t
  val make : int -> t
  val succ : t -> t
  val abs : t -> Name.t list -> t

  val ix_of_lvl : int -> t -> int
  val ix_of_atom : Name.t -> t -> int
end =
struct
  module M = Map.Make (Name)
  type t = {n : int; atoms : int M.t}

  let len env =
    env.n

  let make n =
    {n; atoms = M.empty}

  let emp = make 0

  let succ env =
    {env with n = env.n + 1}

  let abs1 env x =
    {n = env.n + 1;
     atoms = M.add x env.n env.atoms}
  (* TODO: should that be env.n + 1? *)

  (* I might be doing this backwards ;-) *)
  let rec abs env xs =
    match xs with
    | [] -> env
    | x::xs -> abs (abs1 env x) xs

  let ix_of_lvl l env =
    env.n - (l + 1)

  let ix_of_atom x env =
    try
      let lvl = M.find x env.atoms in
      ix_of_lvl lvl env
    with _ -> failwith "FUCK!!:"
end

type env = Env.t

module type S =
sig
  val quote_nf : env -> Val.nf -> Tm.tm
  val quote_neu : env -> Val.neu -> Tm.tm Tm.cmd
  val quote_ty : env -> Val.value -> Tm.tm

  val equiv : env -> ty:Val.value -> Val.value -> Val.value -> unit
  val equiv_ty : env -> Val.value -> Val.value -> unit
  val subtype : env -> Val.value -> Val.value -> unit
end

module M (V : Val.S) : S =
struct
  module QEnv = Env
  open V
  module Env = QEnv

  let generic_constrained env ty sys =
    reflect ty (Lvl (None, Env.len env)) sys

  let generic env ty =
    generic_constrained env ty []


  let rec equate env ty el0 el1 =
    match unleash ty with
    | Pi {dom; cod} ->
      let var = generic env dom in
      let vcod = inst_clo cod var in
      let app0 = apply el0 var in
      let app1 = apply el1 var in
      Tm.lam (clo_name cod) @@ equate (Env.succ env) vcod app0 app1
    | Sg {dom; cod} ->
      let el00 = car el0 in
      let el10 = car el1 in
      let q0 = equate env dom el00 el10 in
      let vcod = inst_clo cod el00 in
      let q1 = equate env vcod (cdr el0) (cdr el1) in
      Tm.cons q0 q1
    | Ext abs ->
      let xs, (tyx, _) = ExtAbs.unleash abs in
      let rs = List.map (fun x -> `Atom x) xs in
      let app0 = ext_apply el0 rs in
      let app1 = ext_apply el1 rs in
      Tm.ext_lam (List.map Name.name xs) @@
      equate (Env.abs env xs) tyx app0 app1

    | Rst {ty; _} ->
      equate env ty el0 el1

    | CoR face ->
      begin
        match face with
        | Face.False p ->
          let r, r' = IStar.unleash p in
          let tr = quote_dim env r in
          let tr' = quote_dim env r' in
          Tm.make @@ Tm.CoRThunk (tr, tr', None)

        | Face.True (r, r', ty) ->
          let tr = quote_dim env r in
          let tr' = quote_dim env r' in
          let force0 = corestriction_force el0 in
          let force1 = corestriction_force el1 in
          let tm = equate env ty force0 force1 in
          Tm.make @@ Tm.CoRThunk (tr, tr', Some tm)

        | Face.Indet (p, ty) ->
          let r, r' = IStar.unleash p in
          let tr = quote_dim env r in
          let tr' = quote_dim env r' in
          let phi = I.equate r r' in
          let force0 = corestriction_force @@ Val.act phi el0 in
          let force1 = corestriction_force @@ Val.act phi el1 in
          let tm = equate env ty force0 force1 in
          Tm.make @@ Tm.CoRThunk (tr, tr', Some tm)
      end

    | LblTy {ty; _} ->
      let call0 = lbl_call el0 in
      let call1 = lbl_call el1 in
      let qcall = equate env ty call0 call1 in
      Tm.make @@ Tm.LblRet qcall

    | V info ->
      let tr = quote_dim env @@ `Atom info.x in
      let phi_r0 = I.subst `Dim0 info.x in
      let tm0 = equate env (Val.act phi_r0 info.ty0) (Val.act phi_r0 el0) (Val.act phi_r0 el1) in
      let vproj0 = rigid_vproj info.x ~ty0:info.ty0 ~ty1:info.ty1 ~equiv:info.equiv ~el:el0 in
      let vproj1 = rigid_vproj info.x ~ty0:info.ty0 ~ty1:info.ty1 ~equiv:info.equiv ~el:el1 in
      let tm1 = equate env info.ty1 vproj0 vproj1 in
      Tm.make @@ Tm.VIn {r = tr; tm0; tm1}

    | _ ->
      match unleash el0, unleash el1 with
      | Univ info0, Univ info1 ->
        if info0.kind = info1.kind && info0.lvl = info1.lvl then
          Tm.univ ~kind:info0.kind ~lvl:info0.lvl
        else
          failwith "Expected equal universe levels"

      | Bool, Bool ->
        Tm.make Tm.Bool

      | Tt, Tt ->
        Tm.make Tm.Tt

      | Ff, Ff ->
        Tm.make Tm.Ff

      | Pi pi0, Pi pi1 ->
        let dom = equate env ty pi0.dom pi1.dom in
        let var = generic env pi0.dom in
        let vcod0 = inst_clo pi0.cod var in
        let vcod1 = inst_clo pi1.cod var in
        let cod = equate (Env.succ env) ty vcod0 vcod1 in
        Tm.pi (clo_name pi0.cod) dom cod

      | Sg sg0, Sg sg1 ->
        let dom = equate env ty sg0.dom sg1.dom in
        let var = generic env sg0.dom in
        let vcod0 = inst_clo sg0.cod var in
        let vcod1 = inst_clo sg1.cod var in
        let cod = equate (Env.succ env) ty vcod0 vcod1 in
        Tm.sg (clo_name sg0.cod) dom cod

      | Ext abs0, Ext abs1 ->
        let xs, (ty0x, sys0x) = ExtAbs.unleash abs0 in
        let ty1x, sys1x = ExtAbs.inst abs1 @@ List.map (fun x -> `Atom x) xs in
        let envx = Env.abs env xs in
        let tyx = equate envx ty ty0x ty1x in
        let sysx = equate_val_sys envx ty0x sys0x sys1x in
        Tm.make @@ Tm.Ext (Tm.NB (List.map Name.name xs, (tyx, sysx)))

      | Rst info0, Rst info1 ->
        let ty = equate env ty info0.ty info1.ty in
        let sys = equate_val_sys env info0.ty info0.sys info1.sys in
        Tm.make @@ Tm.Rst {ty; sys}

      | CoR face0, CoR face1 ->
        let univ = V.make @@ Univ {lvl = Lvl.Omega; kind = Kind.Pre} in
        let face = equate_val_face env univ face0 face1 in
        Tm.make @@ Tm.CoR face

      | V info0, V info1 ->
        let x0 = info0.x in
        let x1 = info1.x in
        let tr = equate_atom env x0 x1 in
        let ty0 = equate_ty env info0.ty0 info1.ty0 in
        let ty1 = equate_ty env info0.ty1 info1.ty1 in
        let equiv_ty = V.Macro.equiv info0.ty0 info1.ty1 in
        let equiv = equate env equiv_ty info0.equiv info1.equiv in
        Tm.make @@ Tm.V {r = tr; ty0; ty1; equiv}

      | Box info0, Box info1 ->
        let dir, ty_cap, ty_sys = unleash_fcom ty in
        let _, s' = IStar.unleash dir in
        let tr, tr' = equate_star3 env dir info0.dir info1.dir in
        let tcap = equate env ty_cap info0.cap info1.cap in
        let tsys = equate_box_sys env s' ty_sys info0.sys info1.sys in
        Tm.make @@ Tm.Box {r = tr; r' = tr'; cap = tcap; sys = tsys}

      | LblTy info0, LblTy info1 ->
        if info0.lbl != info1.lbl then failwith "Labelled type mismatch" else
          let ty = equate env ty info0.ty info1.ty in
          let go_arg (nf0, nf1) =
            let ty = equate_ty env nf0.ty nf1.ty in
            let tm = equate env nf0.ty nf0.el nf1.el in
            ty, tm
          in
          let args = List.map go_arg @@ List.combine info0.args info1.args in
          Tm.make @@ Tm.LblTy {lbl = info0.lbl; ty; args}

      | Up up0, Up up1 ->
        Tm.up @@ equate_neu env up0.neu up1.neu

      | FCom fcom0, FCom fcom1 ->
        let tr, tr' = equate_star env fcom0.dir fcom1.dir in
        let cap = equate env ty fcom0.cap fcom1.cap in
        let sys = equate_comp_sys env ty fcom0.sys fcom1.sys in
        Tm.make @@ Tm.FCom {r = tr; r' = tr'; cap; sys}

      | HCom hcom0, HCom hcom1 ->
        begin
          try
            let tr, tr' = equate_star env hcom0.dir hcom1.dir in
            let ty = equate_ty env hcom0.ty hcom1.ty in
            let cap = equate env hcom0.ty hcom0.cap hcom1.cap in
            let sys = equate_comp_sys env hcom0.ty hcom0.sys hcom1.sys in
            Tm.up (Tm.HCom {r = tr; r' = tr'; ty; cap; sys}, Emp)
          with
          | exn -> Format.eprintf "equating: %a <> %a@." pp_value el0 pp_value el1; raise exn
        end

      | Coe coe0, Coe coe1 ->
        let tr, tr' = equate_star env coe0.dir coe1.dir in
        let univ = make @@ Univ {kind = Kind.Pre; lvl = Lvl.Omega} in
        let bnd = equate_val_abs env univ coe0.abs coe1.abs in
        let tyr =
          let r, _ = IStar.unleash coe0.dir in
          Abs.inst1 coe0.abs r
        in
        let tm = equate env tyr coe0.el coe1.el in
        Tm.up (Tm.Coe {r = tr; r' = tr'; ty = bnd; tm}, Emp)

      | GHCom ghcom0, GHCom ghcom1 ->
        begin
          try
            let tr, tr' = equate_star env ghcom0.dir ghcom1.dir in
            let ty = equate_ty env ghcom0.ty ghcom1.ty in
            let cap = equate env ghcom0.ty ghcom0.cap ghcom1.cap in
            let sys = equate_comp_sys env ghcom0.ty ghcom0.sys ghcom1.sys in
            Tm.up (Tm.GHCom {r = tr; r' = tr'; ty; cap; sys}, Emp)
          with
          | exn -> Format.eprintf "equating: %a <> %a@." pp_value el0 pp_value el1; raise exn
        end

      | _ ->
        (* Format.eprintf "Failed to equate@; @[<1>%a = %a ∈ %a@] @." pp_value el0 pp_value el1 pp_value ty; *)
        failwith "equate"

  and equate_neu_ env neu0 neu1 stk =
    match neu0, neu1 with
    | Lvl (_, l0), Lvl (_, l1) ->
      if l0 = l1 then
        (* TODO: twin *)
        Tm.Ix (Env.ix_of_lvl l0 env, `Only), Bwd.from_list stk
      else
        failwith @@ "equate_neu: expected equal de bruijn levels, but got " ^ string_of_int l0 ^ " and " ^ string_of_int l1
    | Var info0, Var info1 ->
      if info0.name = info1.name && info0.twin = info1.twin && info0.ushift = info1.ushift then
        Tm.Var {name = info0.name; twin = info0.twin; ushift = info0.ushift}, Bwd.from_list stk
      else
        failwith "global variable name mismatch"
    | Meta meta0, Meta meta1 ->
      if meta0.name = meta1.name && meta0.ushift = meta1.ushift then
        Tm.Meta {name = meta0.name; ushift = meta0.ushift}, Bwd.from_list stk
      else
        failwith "global variable name mismatch"
    | Car neu0, Car neu1 ->
      equate_neu_ env neu0 neu1 @@ Tm.Car :: stk
    | Cdr neu0, Cdr neu1 ->
      equate_neu_ env neu0 neu1 @@ Tm.Cdr :: stk
    | FunApp (neu0, nf0), FunApp (neu1, nf1) ->
      let t = equate env nf0.ty nf0.el nf1.el in
      equate_neu_ env neu0 neu1 @@ Tm.FunApp t :: stk
    | ExtApp (neu0, rs0), ExtApp (neu1, rs1) ->
      let ts = equate_dims env rs0 rs1 in
      equate_neu_ env neu0 neu1 @@ Tm.ExtApp ts :: stk
    | If if0, If if1 ->
      let var = generic env @@ make Bool in
      let vmot0 = inst_clo if0.mot var in
      let vmot1 = inst_clo if1.mot var in
      let mot = equate_ty (Env.succ env) vmot0 vmot1 in
      let vmot_tt = inst_clo if0.mot @@ make Tt in
      let vmot_ff = inst_clo if0.mot @@ make Ff in
      let tcase = equate env vmot_tt if0.tcase if1.tcase in
      let fcase = equate env vmot_ff if0.fcase if1.fcase in
      let frame = Tm.If {mot = Tm.B (clo_name if0.mot, mot); tcase; fcase} in
      equate_neu_ env if0.neu if1.neu @@ frame :: stk
    | VProj vproj0, VProj vproj1 ->
      let x0 = vproj0.x in
      let x1 = vproj1.x in
      let tr = equate_atom env x0 x1 in
      let ty0 = equate_ty env vproj0.ty0 vproj1.ty0 in
      let ty1 = equate_ty env vproj0.ty1 vproj1.ty1 in
      let equiv_ty = V.Macro.equiv vproj0.ty0 vproj0.ty1 in
      let phi = I.subst `Dim0 x0 in
      let equiv = equate env (Val.act phi equiv_ty) vproj0.equiv vproj1.equiv in
      let frame = Tm.VProj {r = tr; ty0; ty1; equiv} in
      equate_neu_ env vproj0.neu vproj1.neu @@ frame :: stk
    | Cap cap0, Cap cap1 ->
      let tr, tr' = equate_star env cap0.dir cap1.dir in
      let ty = equate_ty env cap0.ty cap1.ty in
      let univ = make @@ Univ {kind = Kind.Pre; lvl = Lvl.Omega} in
      let sys = equate_comp_sys env univ cap0.sys cap1.sys in
      let frame = Tm.Cap {r = tr; r' = tr'; ty; sys} in
      equate_neu_ env cap0.neu cap1.neu @@ frame :: stk
    | LblCall neu0, LblCall neu1 ->
      equate_neu_ env neu0 neu1 @@ Tm.LblCall :: stk
    | CoRForce neu0, CoRForce neu1 ->
      equate_neu_ env neu0 neu1 @@ Tm.CoRForce :: stk
    | _ ->
      (* Format.printf "Tried to equate %a with %a@." pp_neu neu0 pp_neu neu1; *)
      failwith "equate_neu"

  and equate_neu env neu0 neu1 =
    equate_neu_ env neu0 neu1 []

  and equate_ty env ty0 ty1 =
    let univ = make @@ Univ {kind = Kind.Pre; lvl = Lvl.Omega} in
    equate env univ ty0 ty1


  and equate_val_sys env ty sys0 sys1 =
    try
      List.map2 (equate_val_face env ty) sys0 sys1
    with
    | Invalid_argument _ ->
      failwith "equate_val_sys length mismatch"

  and equate_comp_sys env ty sys0 sys1 =
    try
      List.map2 (equate_comp_face env ty) sys0 sys1
    with
    | Invalid_argument _ ->
      failwith "equate_cmop_sys length mismatch"

  and equate_box_sys env s' sys_ty sys0 sys1 =
    let rec map3 f xs ys zs  =
      match xs, ys, zs with
      | [], [], [] -> []
      | (x::xs), (y::ys), (z::zs) -> f x y z :: map3 f xs ys zs
      | _ -> raise (Invalid_argument "map3")
    in
    try
      map3 (equate_box_boundary env s') sys_ty sys0 sys1
    with
    | Invalid_argument _ ->
      failwith "equate_cmop_sys length mismatch"


  and equate_val_face env ty face0 face1 =
    match face0, face1 with
    | Face.True (r0, r'0, v0), Face.True (r1, r'1, v1) ->
      let tr = equate_dim env r0 r1 in
      let tr' = equate_dim env r'0 r'1 in
      let t = equate env ty v0 v1 in
      tr, tr', Some t

    | Face.False p0, Face.False p1 ->
      let tr, tr' = equate_star env p0 p1 in
      tr, tr', None

    | Face.Indet (p0, v0), Face.Indet (p1, v1) ->
      let r, r' = IStar.unleash p0 in
      let phi = I.equate r r' in
      let tr, tr' = equate_star env p0 p1 in
      let v = equate env (Val.act phi ty) v0 v1 in
      tr, tr', Some v

    | _ -> failwith "equate_val_face"

  and equate_comp_face env ty face0 face1 =
    match face0, face1 with
    | Face.Indet (p0, abs0), Face.Indet (p1, abs1) ->
      let r, r' = IStar.unleash p0 in
      let phi = I.equate r r' in
      let tr, tr' = equate_star env p0 p1 in
      let bnd = equate_val_abs env (Val.act phi ty) abs0 abs1 in
      tr, tr', Some bnd

  and equate_box_boundary env s' ty bdry0 bdry1 =
    match ty, bdry0, bdry1 with
    | Face.Indet (p_ty, abs), Face.Indet (p0, b0), Face.Indet (p1, b1) ->
      let tr, tr' = equate_star3 env p_ty p0 p1 in
      let b = equate env (Abs.inst1 abs s') b0 b1 in
      tr, tr', Some b

  and equate_val_abs env ty abs0 abs1 =
    let x, v0x = Abs.unleash1 abs0 in
    let v1x = Abs.inst1 abs1 @@ `Atom x in
    try
      let envx = Env.abs env [x] in
      let tm = equate envx ty v0x v1x in
      Tm.B (Name.name x, tm)
    with
    | exn ->
      (* Format.eprintf "Failed to equate abs: @[<v>%a@,= %a@]@." pp_abs abs0 pp_abs abs1; *)
      raise exn

  and equate_star env p0 p1 =
    let r0, r'0 = IStar.unleash p0 in
    let r1, r'1 = IStar.unleash p1 in
    let tr = equate_dim env r0 r1 in
    let tr' = equate_dim env r'0 r'1 in
    tr, tr'

  and equate_star3 env p0 p1 p2 =
    let r0, r'0 = IStar.unleash p0 in
    let r1, r'1 = IStar.unleash p1 in
    let r2, r'2 = IStar.unleash p2 in
    let tr = equate_dim3 env r0 r1 r2 in
    let tr' = equate_dim3 env r'0 r'1 r'2 in
    tr, tr'

  and equate_dim env (r : I.t) (r' : I.t) =
    match I.compare r r' with
    | `Same ->
      quote_dim env r
    | _ ->
      (* Printexc.print_raw_backtrace stderr (Printexc.get_callstack 20);
         Format.eprintf "@.";
         Format.eprintf "Dimension mismatch: %a <> %a@." I.pp r I.pp r'; *)
      failwith "equate_dim: dimensions did not match"

  and equate_dim3 env (r : I.t) (r' : I.t) (r'' : I.t) =
    match I.compare r r', I.compare r r'' with
    | `Same, `Same ->
      quote_dim env r
    | _ ->
      (* Printexc.print_raw_backtrace stderr (Printexc.get_callstack 20);
         Format.eprintf "@.";
         Format.eprintf "Dimension mismatch: %a <> %a@." I.pp r I.pp r'; *)
      failwith "equate_dim3: dimensions did not match"

  and equate_atom env x y =
    if x = y then
      quote_dim env @@ `Atom x
    else
      failwith "equate_atom: dimensions did not match"

  and equate_dims env rs rs' =
    match rs, rs' with
    | [], [] ->
      []
    | r :: rs, r' :: rs' ->
      let r'' = equate_dim env r r' in
      r'' :: equate_dims env rs rs'
    | _ ->
      failwith "equate_dims: length mismatch"

  and quote_dim env r =
    match r with
    | `Dim0 -> Tm.make Tm.Dim0
    | `Dim1 -> Tm.make Tm.Dim1
    | `Atom x ->
      try
        let ix = Env.ix_of_atom x env in
        Tm.up @@ Tm.ix ix
      with
      | _ ->
        Tm.up @@ Tm.var x

  let equiv env ~ty el0 el1 =
    ignore @@ equate env ty el0 el1

  let equiv_ty env ty0 ty1 =
    ignore @@ equate_ty env ty0 ty1

  let quote_ty env ty =
    equate_ty env ty ty

  let quote_nf env nf =
    equate env nf.ty nf.el nf.el

  let quote_neu env neu =
    equate_neu env neu neu

  let rec subtype env ty0 ty1 =
    match unleash ty0, unleash ty1 with
    | Pi pi0, Pi pi1 ->
      subtype env pi1.dom pi0.dom;
      let var = generic env pi0.dom in
      let vcod0 = inst_clo pi0.cod var in
      let vcod1 = inst_clo pi1.cod var in
      subtype (Env.succ env) vcod0 vcod1

    | Sg sg0, Sg sg1 ->
      subtype env sg0.dom sg1.dom;
      let var = generic env sg0.dom in
      let vcod0 = inst_clo sg0.cod var in
      let vcod1 = inst_clo sg1.cod var in
      subtype (Env.succ env) vcod0 vcod1

    | Ext abs0, Ext abs1 ->
      let xs, (ty0x, sys0x) = ExtAbs.unleash abs0 in
      let ty1x, sys1x = ExtAbs.inst abs1 @@ List.map (fun x -> `Atom x) xs in
      let envx = Env.abs env xs in
      subtype envx ty0x ty1x;
      approx_restriction envx ty0x ty1x sys0x sys1x

    | LblTy info0, LblTy info1 ->
      if info0.lbl != info1.lbl then failwith "Labelled type mismatch" else
        subtype env info0.ty info1.ty;
      let go_arg (nf0, nf1) =
        equiv_ty env nf0.ty nf1.ty;
        equiv env nf0.ty nf0.el nf1.el
      in
      ignore @@ List.map go_arg @@ List.combine info0.args info1.args

    | Univ info0, Univ info1 ->
      if Kind.lte info0.kind info1.kind && Lvl.lte info0.lvl info1.lvl then
        ()
      else
        failwith "Universe subtyping error"


    (* The following code is kind of complicated. What it does is the following:
       1. First, turn both sides into a restriction type somehow.
       2. Then, using a generic element, check that the restriction of the lhs implies the restriction of the rhs.
    *)
    | Rst rst0, con1 ->
      let ty0, sys0 = rst0.ty, rst0.sys in
      let ty1, sys1 =
        match con1 with
        | Rst rst1 -> rst1.ty, rst1.sys
        | _ -> ty1, []
      in
      subtype env ty0 ty1;
      approx_restriction env ty0 ty1 sys0 sys1

    | _ ->
      equiv_ty env ty0 ty1

  and approx_restriction env ty0 ty1 sys0 sys1 =
    (* A semantic indeterminate of the first type *)
    let gen = generic_constrained env ty0 sys0 in

    let check_face face =
      match face with
      | Face.True (_, _, v) ->
        (* In this case, we need to see that the indeterminate is already equal to the face *)
        begin try equiv env ~ty:ty1 gen v; true with _ -> false end

      | Face.False _ ->
        (* This one is vacuous *)
        false

      | Face.Indet (p, v) ->
        (* In this case, we check that the semantic indeterminate will become equal to the face under the
           stipulated restriction. *)
        let r, r' = IStar.unleash p in
        let gen_rr' = Val.act (I.equate r r') gen in
        let ty_rr' = Val.act (I.equate r r') ty1 in
        begin try equiv env ~ty:ty_rr' gen_rr' v; true with _ -> false end
    in

    (* This algorithm is very wrong ;-) *)
    let exception Break in
    let n1 = List.length sys1 in
    begin
      try
        for i = 0 to n1 - 1 do
          if check_face (List.nth sys1 i) then () else raise Break
        done
      with
      | Break ->
        failwith "restriction subtyping"
      | exn ->
        Format.eprintf "Unexpected error in subtyping: %s@." (Printexc.to_string exn);
        raise exn
    end

end