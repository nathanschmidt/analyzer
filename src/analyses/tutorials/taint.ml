(** An analysis specification for didactic purposes. *)
(* Helpful link on CIL: https://goblint.in.tum.de/assets/goblint-cil/ *)
(* Goblint documentation: https://goblint.readthedocs.io/en/latest/ *)
(* You may test your analysis on our toy examples by running `ruby scripts/update_suite.rb group tutorials` *)
(* after removing the `SKIP` from the beginning of the tests in tests/regression/99-tutorials/{03-taint_simple.c,04-taint_inter.c} *)

open Prelude.Ana
open Analyses

module VarinfoSet = SetDomain.Make(CilType.Varinfo)

(* Use to check if a specific function is a sink / source *)
let is_sink varinfo = Cil.hasAttribute "taint_sink" varinfo.vattr
let is_source varinfo = Cil.hasAttribute "taint_source" varinfo.vattr


(** "Fake" variable to handle returning from a function *)
let return_varinfo = dummyFunDec.svar

module Spec : Analyses.MCPSpec =
struct
  include Analyses.DefaultSpec

  let name () = "taint"
  module D = MapDomain.MapBot (Basetype.Variables) (BoolDomain.MustBool) (* TODO: Change such that you have a fitting local domain -- DONE *)
  module C = Lattice.Unit

  (* We are context insensitive in this analysis *)
  let context _ _ = ()

  (** Determines whether an expression [e] is tainted, given a [state]. *)
  let rec is_exp_tainted (state:D.t) (e:Cil.exp) = match e with
    (* Recurse over the structure in the expression, returning true if any varinfo appearing in the expression is tainted *)
    | AddrOf v
    | StartOf v
    | Lval v -> is_lval_tainted state v
    | BinOp (_,e1,e2,_) -> is_exp_tainted state e1 || is_exp_tainted state e2
    | Real e
    | Imag e
    | SizeOfE e
    | AlignOfE e
    | CastE (_,e)
    | UnOp (_,e,_) -> is_exp_tainted state e
    | SizeOf _ | SizeOfStr _ | Const _  | AlignOf _ | AddrOfLabel _ -> false
    | Question (b, t, f, _) -> is_exp_tainted state b || is_exp_tainted state t || is_exp_tainted state f
  and is_lval_tainted state = function
    | (Var v, _) -> 
      (* TODO: Check whether variable v is tainted -- DONE *)
      (match D.find_opt v state
       with Some x -> x
          | None -> false)
    | _ ->
      (* We assume using a tainted offset does not taint the expression, and that our language has no pointers *)
      false

  (* transfer functions *)

  (** Handles assignment of [rval] to [lval]. *)
  let assign ctx (lval:lval) (rval:exp) : D.t =
    let state = ctx.local in
    match lval with
    | Var v,_ ->
      (* TODO: Check whether rval is tainted, handle assignment to v accordingly -- DONE *)
      if is_exp_tainted state rval
        then D.add v true state
      else
        D.add v false state
    | _ -> state

  (** Handles conditional branching yielding truth value [tv]. *)
  let branch ctx (exp:exp) (tv:bool) : D.t =
    (* Nothing needs to be done *)
    ctx.local

  (** Handles going from start node of function [f] into the function body of [f].
      Meant to handle e.g. initializiation of local variables. *)
  let body ctx (f:fundec) : D.t =
    (* Nothing needs to be done here, as the (non-formals) locals are initally untainted *)
    ctx.local

  (** Handles the [return] statement, i.e. "return exp" or "return", in function [f]. *)
  let return ctx (exp:exp option) (f:fundec) : D.t =
    let state = ctx.local in
    match exp with
    | Some e ->
      (* TODO: Record whether a tainted value was returned. -- DONE *)
      (* Hint: You may use return_varinfo in place of a variable. *)
      if is_exp_tainted state e
        then D.add return_varinfo true state
      else
        D.add return_varinfo false state
    | None -> state

  (** For a function call "lval = f(args)" or "f(args)",
      [enter] returns a caller state, and the initial state of the callee.
      In [enter], the caller state can usually be returned unchanged, as [combine_env] and [combine_assign] (below)
      will compute the caller state after the function call, given the return state of the callee. *)
  let enter ctx (lval: lval option) (f:fundec) (args:exp list) : (D.t * D.t) list =
    let caller_state = ctx.local in
    (* Create list of (formal, actual_exp)*)
    let zipped = List.combine f.sformals args in
    (* TODO: For the initial callee_state, collect formal parameters where the actual is tainted. -- DONE *)
    let callee_state = List.fold_left (fun ts (f,a) ->
        if is_exp_tainted caller_state a
        then D.add f true ts (* TODO: Change accumulator ts here? -- DONE *)
        else ts)
        (D.bot ())
        zipped in
    (* first component is state of caller, second component is state of callee *)
    [caller_state, callee_state]

  (** For a function call "lval = f(args)" or "f(args)",
      computes the global environment state of the caller after the call.
      Argument [callee_local] is the state of [f] at its return node. *)
  let combine_env ctx (lval:lval option) fexp (f:fundec) (args:exp list) fc (callee_local:D.t) (f_ask: Queries.ask): D.t =
    (* Nothing needs to be done *)
    ctx.local

  (** For a function call "lval = f(args)" or "f(args)",
      computes the state of the caller after assigning the return value from the call.
      Argument [callee_local] is the state of [f] at its return node. *)
  let combine_assign ctx (lval:lval option) fexp (f:fundec) (args:exp list) fc (callee_local:D.t) (f_ask: Queries.ask): D.t =
    let caller_state = ctx.local in
    (* TODO: Record whether lval was tainted. -- DONE *)
    match lval
    with Some (Var v, _) -> (match D.find_opt return_varinfo callee_local
                             with Some r -> D.add v r caller_state
                                | _ -> caller_state)
       | _ -> caller_state

  (** For a call to a _special_ function f "lval = f(args)" or "f(args)",
      computes the caller state after the function call.
      For this analysis, source and sink functions will be considered _special_ and have to be treated here. *)
  let special ctx (lval: lval option) (f:varinfo) (arglist:exp list) : D.t =
    let caller_state = ctx.local in
    (* TODO: Check if f is a sink / source and handle it appropriately -- DONE *)
    if is_sink f
    then (List.iter (fun a -> if is_exp_tainted caller_state a then M.warn "Tainted variable reaching sink") arglist;
          caller_state)
    else if is_source f
    then match lval
      with Some (Var v, _) -> D.add v true caller_state
         | _ -> caller_state
    else
      match lval
      with Some (Var v, _) -> if List.exists (is_exp_tainted caller_state) arglist
        then D.add v true caller_state
        else
          D.add v false caller_state
         | _ -> caller_state

  (* You may leave these alone *)
  let startstate v = D.bot ()
  let threadenter ctx lval f args = [D.top ()]
  let threadspawn ctx lval f args fctx = ctx.local
  let exitstate  v = D.top ()
end

let _ =
  MCP.register_analysis (module Spec : MCPSpec)
