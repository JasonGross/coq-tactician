open Tactic_learner_internal
open TS
open Constr
open Monad_util
open Map_all_the_things
open Genarg
open Glob_term

(* This file has the purpose of dealing with side effects of the `abstract` tactic and schemes. This is all very
   uninteresting, but has to be dealt with because the constants `abstract` generates disappear, which
   result in lookup errors.

   For opaque proofs, we add any side-effects to the local context, which is somewhat consistent because the final
   proof term will have the side-effects added as let-in's and lambdas anyway.
   This is not a perfect solution, but at least everything is well-typed
*)

module TacticFinderDef = struct
  include MapDefTemplate (IdentityMonad)
  let map_sort = "tactic-finder"
  let warnProblem wit =
    Feedback.msg_warning (Pp.(str "Tactician is having problems with " ++
                              str "the following tactic. Please report. " ++
                              pr_argument_type wit))
  let default wit = { raw = (fun _ -> warnProblem (ArgumentType wit); id)
                    ; glb = (fun _ -> warnProblem (ArgumentType wit); id)}
end
module TacticFinderMapper = MakeMapper(TacticFinderDef)
open TacticFinderDef

let inline_tactic env t =
  (* TODO: Sometimes we cannot properly change a constant into a variable. This notably occurs for
     the unfold tactic. To fix this, the mapper should allow us to map a `Tacexpr.g_cst` *)
  let mapper = { TacticFinderDef.default_mapper with
                 glob_constr = (fun t c ->
                     let t = match t with
                     | GRef (ConstRef const, l) when not @@ Environ.mem_constant const env ->
                       GRef (VarRef (Names.Label.to_id @@ Names.Constant.label const), l)
                     | _ -> t in
                     c t)
               ; constant = (fun const ->
                     if Environ.mem_constant const env then const else
                       (match Coqlib.lib_ref "tactician.private_constant_placeholder" with
                        | Names.GlobRef.ConstRef const -> const
                        | _ -> assert false)
                   )
               } in
  TacticFinderMapper.glob_tactic_expr_map mapper t

let inline env extra_ctx extra_substs { outcomes; tactic; name; status; path } =
  let rec inline_constr c = match Constr.kind c with
    | Const (const, _u) ->
      if Environ.mem_constant const env then c else
        Constr.mkVar (Names.Label.to_id @@ Names.Constant.label const)
    | _ -> Constr.map inline_constr c in
  let rec shift_evars c = match Constr.kind c with
    | Evar (ev, substs) -> Constr.mkEvar (ev, Array.append extra_substs substs)
    | _ -> Constr.map shift_evars c in
  let inline_single_proof_state (ctx, goal, evar) =
    let ctx = List.map (Context.Named.Declaration.map_constr inline_constr) (List.rev extra_ctx @ ctx) in
    let goal = inline_constr goal in
    ctx, goal, evar in
  let inline_proof_state (map, ps) =
    Evar.Map.map inline_single_proof_state map, inline_single_proof_state ps in
  let rec inline_proof_dag = function
    | End -> End
    | Step step -> Step (inline_proof_step step)
  and inline_proof_step { executions; tactic } =
    { executions = List.map (fun (pse, psp) -> inline_proof_state pse, inline_proof_dag psp) executions
    ; tactic = tactic } in
  let inline_result (term, map, pss) =
    shift_evars @@ inline_constr term,
    Evar.Map.map inline_single_proof_state map,
    List.map inline_single_proof_state pss in
  let inline_outcome { parents; siblings; before; result } =
    { parents = List.map (fun (pse, psp) -> inline_proof_state pse, inline_proof_step psp) parents
    ; siblings = inline_proof_dag siblings
    ; before = inline_proof_state before
    ; result = inline_result result } in
  { outcomes = List.map inline_outcome outcomes
  ; tactic = Option.map (fun tac -> tactic_make @@ inline_tactic env @@ tactic_repr tac) tactic
  ; name; status; path }

let inline env sideff t =
  let open Declarations in
  let open Context.Named.Declaration in
  let open Names in
  if sideff = Safe_typing.empty_private_constants then t else
    let doc = Stm.get_doc 0 in
    let should_inline = Option.cata (fun CAst.{ loc; v } ->
        let open Vernacexpr in
        match v.expr with
        | VernacEndProof (Proved (Proof_global.Opaque, _)) -> true
        | VernacEndProof (Vernacexpr.Proved (Proof_global.Transparent, _)) -> false
        | _ -> CErrors.anomaly Pp.(str "Unexpected vernac ast during Tactician side-effect inlining")) true @@
      Stm.(get_ast ~doc (get_current_state ~doc)) in
    if not should_inline then t else
      let (_, consts), senv = Safe_typing.export_private_constants
          ((Constr.mkSort Sorts.set, Univ.ContextSet.empty), sideff) (Global.safe_env ()) in
      let extra_ctx = List.map (fun c ->
          let id = Context.annotR @@ Label.to_id @@ Constant.label c in
          let { const_body; const_type; _ } = Environ.lookup_constant c @@ Safe_typing.env_of_safe_env senv in
          match const_body with
          | Primitive _ | Undef _ ->
            CErrors.anomaly Pp.(str "Unexpected constant body encountered during Tactician side-effect inlining")
          | Def body -> LocalDef (id, Mod_subst.force_constr body, const_type)
          | OpaqueDef _ -> LocalAssum (id, const_type)
        ) consts in
      let extra_substs = Array.of_list @@
        List.map (fun c -> Constr.mkVar @@ Label.to_id @@ Constant.label c) consts in
      inline env extra_ctx extra_substs t
