(** Analysis of correct file handle usage ([file]).

    @see <https://www2.in.tum.de/hp/file?fid=1323> Vogler, R. Verifying Regular Safety Properties of C Programs Using the Static Analyzer Goblint. Section 3.*)

open Batteries
open GoblintCil
open Analyses

module Spec =
struct
  include Analyses.DefaultSpec

  let name () = "file"
  module D = FileDomain.Dom
  module C = FileDomain.Dom

  (* special variables *)
  let return_var    = Cilfacade.create_var @@ Cil.makeVarinfo false "@return"    Cil.voidType, `NoOffset
  let unclosed_var  = Cilfacade.create_var @@ Cil.makeVarinfo false "@unclosed"  Cil.voidType, `NoOffset

  (* keys that were already warned about; needed for multiple returns (i.e. can't be kept in D) *)
  let warned_unclosed = ref Set.empty

  (* queries *)
  let query ctx (type a) (q: a Queries.t) =
    match q with
    | Queries.MayPointTo exp -> if M.tracing then M.tracel "file" "query MayPointTo: %a" d_plainexp exp; Queries.Result.top q
    | _ -> Queries.Result.top q

  let query_ad (ask: Queries.ask) exp =
    match ask.f (Queries.MayPointTo exp) with
    | ad when not (Queries.AD.is_top ad) -> Queries.AD.elements ad
    | _ -> []
  let print_query_lv ?msg:(msg="") ask exp =
    let addrs = query_ad ask exp in (* MayPointTo -> LValSet *)
    let pretty_key = function
      | Queries.AD.Addr.Addr (v,o) -> Pretty.text (D.string_of_key (v, ValueDomain.Addr.Offs.to_exp o))
      | _ -> Pretty.text "" in
    if M.tracing then M.tracel "file" "%s MayPointTo %a = [%a]" msg d_exp exp (Pretty.docList ~sep:(Pretty.text ", ") pretty_key) addrs

  let eval_fv ask exp: varinfo option =
    match query_ad ask exp with
    | [addr] -> Queries.AD.Addr.to_var_may addr
    | _ -> None


  (* transfer functions *)
  let assign ctx (lval:lval) (rval:exp) : D.t =
    let m = ctx.local in
    (* ignore(printf "%a = %a\n" d_plainlval lval d_plainexp rval); *)
    let saveOpened ?unknown:(unknown=false) k m = (* save maybe opened files in the domain to warn about maybe unclosed files at the end *)
      if D.may k D.opened m && not (D.is_unknown k m) then (* if unknown we don't have any location for the warning and have handled it already anyway *)
        let mustOpen, mayOpen = D.filter_records k D.opened m in
        let mustOpen, mayOpen = if unknown then Set.empty, mayOpen else mustOpen, Set.diff mayOpen mustOpen in
        D.extend_value unclosed_var (mustOpen, mayOpen) m
      else m
    in
    let key_from_exp = function
      | Lval x -> Some (D.key_from_lval x)
      | _ -> None
    in
    match key_from_exp (Lval lval), key_from_exp (stripCasts rval) with (* we just care about Lval assignments *)
    | Some k1, Some k2 when k1=k2 -> m (* do nothing on self-assignment *)
    | Some k1, Some k2 when D.mem k1 m && D.mem k2 m -> (* both in D *)
      if M.tracing then M.tracel "file" "assign (both in D): %s = %s" (D.string_of_key k1) (D.string_of_key k2);
      saveOpened k1 m |> D.remove' k1 |> D.alias k1 k2
    | Some k1, Some k2 when D.mem k1 m -> (* only k1 in D *)
      if M.tracing then M.tracel "file" "assign (only k1 in D): %s = %s" (D.string_of_key k1) (D.string_of_key k2);
      saveOpened k1 m |> D.remove' k1
    | Some k1, Some k2 when D.mem k2 m -> (* only k2 in D *)
      if M.tracing then M.tracel "file" "assign (only k2 in D): %s = %s" (D.string_of_key k1) (D.string_of_key k2);
      D.alias k1 k2 m
    | Some k1, _ when D.mem k1 m -> (* k1 in D and assign something unknown *)
      if M.tracing then M.tracel "file" "assign (only k1 in D): %s = %a" (D.string_of_key k1) d_exp rval;
      D.warn @@ "[Unsound]changed pointer "^D.string_of_key k1^" (no longer safe)";
      saveOpened ~unknown:true k1 m |> D.unknown k1
    | _ -> (* no change in D for other things *)
      if M.tracing then M.tracel "file" "assign (none in D): %a = %a [%a]" d_lval lval d_exp rval d_plainexp rval;
      m

  let branch ctx (exp:exp) (tv:bool) : D.t =
    let m = ctx.local in
    (* ignore(printf "if %a = %B (line %i)\n" d_plainexp exp tv (!Tracing.current_loc).line); *)
    let check a b tv =
      (* ignore(printf "check: %a = %a, %B\n" d_plainexp a d_plainexp b tv); *)
      match a, b with
      | Const (CInt(i, kind, str)), Lval lval
      | Lval lval, Const (CInt(i, kind, str)) ->
        (* ignore(printf "branch(%s==%i, %B)\n" v.vname (Int64.to_int i) tv); *)
        let k = D.key_from_lval lval in
        if Z.compare i Z.zero = 0 && tv then (
          (* ignore(printf "error-branch\n"); *)
          D.error k m
        )else
          D.success k m
      | _ -> M.debug ~category:Analyzer "nothing matched the given BinOp: %a = %a" d_plainexp a d_plainexp b; m
    in
    match stripCasts (constFold true exp) with
    (* somehow there are a lot of casts inside the BinOp which stripCasts only removes when called on the subparts
       -> matching as in flagMode didn't work *)
    (*     | BinOp (Eq, Const (CInt64(i, kind, str)), Lval (Var v, NoOffset), _)
           | BinOp (Eq, Lval (Var v, NoOffset), Const (CInt64(i, kind, str)), _) ->
            ignore(printf "%s %i\n" v.vname (Int64.to_int i)); m *)
    | BinOp (Eq, a, b, _) -> check (stripCasts a) (stripCasts b) tv
    | BinOp (Ne, a, b, _) -> check (stripCasts a) (stripCasts b) (not tv)
    | e -> M.debug ~category:Analyzer "branch: nothing matched the given exp: %a" d_plainexp e; m

  let body ctx (f:fundec) : D.t =
    ctx.local

  let return ctx (exp:exp option) (f:fundec) : D.t =
    (* TODO check One Return transformation: oneret.ml *)
    let m = ctx.local in
    (* if f.svar.vname <> "main" && BatList.is_empty (callstack m) then M.write ("\n\t!!! call stack is empty for function "^f.svar.vname^" !!!"); *)
    if f.svar.vname = "main" then (
      let mustOpen, mayOpen = D.union (D.filter_values D.opened m) (D.get_value unclosed_var m) in
      if Set.cardinal mustOpen > 0 then (
        D.warn @@ "unclosed files: "^D.string_of_keys mustOpen;
        Set.iter (fun v -> D.warn ~loc:(D.V.loc v) "file is never closed") mustOpen;
        (* add warnings about currently open files (don't include overwritten or changed file handles!) *)
        warned_unclosed := Set.union !warned_unclosed (fst (D.filter_values D.opened m)) (* can't save in domain b/c it wouldn't reach the other return *)
      );
      (* go through files "never closed" and recheck for current return *)
      Set.iter (fun v -> if D.must (D.V.key v) D.closed m then D.warn ~may:true ~loc:(D.V.loc v) "file is never closed") !warned_unclosed;
      (* let mustOpenVars = List.map (fun x -> x.key) mustOpen in *)
      (* let mayOpen = List.filter (fun x -> not (List.mem x.key mustOpenVars)) mayOpen in (* ignore values that are already in mustOpen *) *)
      let mayOpen = Set.diff mayOpen mustOpen in
      if Set.cardinal mayOpen > 0 then
        D.warn ~may:true @@ "unclosed files: "^D.string_of_keys mayOpen;
      Set.iter (fun v -> D.warn ~may:true ~loc:(D.V.loc v) "file is never closed") mayOpen
    );
    (* take care of return value *)
    let au = match exp with
      | Some(Lval lval) when D.mem (D.key_from_lval lval) m -> (* we return a var in D *)
        let k = D.key_from_lval lval in
        let varinfo,offset = k in
        if varinfo.vglob then
          D.alias return_var k m (* if var is global, we alias it *)
        else
          D.add return_var (D.find' k m) m (* if var is local, we make a copy *)
      | _ -> m
    in
    (* remove formals and locals *)
    (* this is not a good approach, what if we added a key foo.fp? -> just keep the globals *)
    List.fold_left (fun m var -> D.remove' (var, `NoOffset) m) au (f.sformals @ f.slocals)
  (* D.only_globals au *)

  let enter ctx (lval: lval option) (f:fundec) (args:exp list) : (D.t * D.t) list =
    let m = if f.svar.vname <> "main" then
        (* push current location onto stack *)
        D.edit_callstack (BatList.cons (Option.get !Node.current_node)) ctx.local
      else ctx.local in
    (* we need to remove all variables that are neither globals nor special variables from the domain for f *)
    (* problem: we need to be able to check aliases of globals in check_overwrite_open -> keep those in too :/ *)
    (* TODO see Base.make_entry, reachable vars > globals? *)
    (* [m, D.only_globals m] *)
    [m, m] (* this is [caller, callee] *)

  let check_overwrite_open k m = (* used in combine and special *)
    if List.is_empty (D.get_aliases k m) then (
      (* there are no other variables pointing to the file handle
         and it is opened again without being closed before *)
      D.report k D.opened ("overwriting still opened file handle "^D.string_of_key k) m;
      let mustOpen, mayOpen = D.filter_records k D.opened m in
      let mayOpen = Set.diff mayOpen mustOpen in
      (* save opened files in the domain to warn about unclosed files at the end *)
      D.extend_value unclosed_var (mustOpen, mayOpen) m
    ) else m

  let combine_env ctx lval fexp f args fc au f_ask =
    let m = ctx.local in
    (* pop the last location off the stack *)
    let m = D.edit_callstack List.tl m in (* TODO could it be problematic to keep this in the caller instead of callee domain? if we only add the stack for the callee in enter, then there would be no need to pop a location anymore... *)
    (* TODO add all globals from au to m (since we remove formals and locals on return, we can just add everything except special vars?) *)
    D.without_special_vars au |> D.add_all m

  let combine_assign ctx (lval:lval option) fexp (f:fundec) (args:exp list) fc (au:D.t) (f_ask: Queries.ask) : D.t =
    let m = ctx.local in
    let return_val = D.find_option return_var au in
    match lval, return_val with
    | Some lval, Some v ->
      let k = D.key_from_lval lval in
      (* handle potential overwrites *)
      let m = check_overwrite_open k m in
      (* if v.key is still in D, then it must be a global and we need to alias instead of rebind *)
      (* TODO what if there is a local with the same name as the global? *)
      if D.V.is_top v then (* returned a local that was top -> just add k as top *)
        D.add' k v m
      else (* v is now a local which is not top or a global which is aliased *)
        let vvar = D.V.get_alias v in (* this is also ok if v is not an alias since it chooses an element from the May-Set which is never empty (global top gets aliased) *)
        if D.mem vvar au then (* returned variable was a global TODO what if local had the same name? -> seems to work *)
          D.alias k vvar m
        else (* returned variable was a local *)
          let v = D.V.set_key k v in (* adjust var-field to lval *)
          D.add' k v m
    | _ -> m

  let special ctx (lval: lval option) (f:varinfo) (arglist:exp list) : D.t =
    (* is f a pointer to a function we look out for? *)
    let f = eval_fv (Analyses.ask_of_ctx ctx) (Lval (Var f, NoOffset)) |? f in
    let m = ctx.local in
    let loc = (Option.get !Node.current_node)::(D.callstack m) in
    let arglist = List.map (Cil.stripCasts) arglist in (* remove casts, TODO safe? *)
    let split_err_branch lval dom =
      (* type? NULL = 0 = 0-ptr? Cil.intType, Cil.intPtrType, Cil.voidPtrType -> no difference *)
      if not (GobConfig.get_bool "ana.file.optimistic") then
        ctx.split dom [Events.SplitBranch ((Cil.BinOp (Cil.Eq, Cil.Lval lval, Cil.integer 0, Cil.intType)), true)];
      dom
    in
    (* fold possible keys on domain *)
    let ret_all f lval =
      let xs = D.keys_from_lval lval (Analyses.ask_of_ctx ctx) in (* get all possible keys for a given lval *)
      if xs = [] then (D.warn @@ GobPretty.sprintf "could not resolve %a" CilType.Lval.pretty lval; m)
      else if List.compare_length_with xs 1 = 0 then f (List.hd xs) m true
      (* else List.fold_left (fun m k -> D.join m (f k m)) m xs *)
      else
        (* if there is more than one key, join all values and do warnings on the result *)
        let v = List.fold_left (fun v k -> match v, D.find_option k m with
            | None, None -> None
            | Some a, None
            | None, Some a -> Some a
            | Some a, Some b -> Some (D.V.join a b)) None xs in
        (* set all of the keys to the computed joined value *)
        (* let m' = Option.map_default (fun v -> List.fold_left (fun m k -> D.add' k v m) m xs) m v in *)
        (* then check each key *)
        (* List.iter (fun k -> ignore(f k m')) xs; *)
        (* get Mval.Exp from lval *)
        let k' = D.key_from_lval lval in
        (* add joined value for that key *)
        let m' = Option.map_default (fun v -> D.add' k' v m) m v in
        (* check for warnings *)
        ignore(f k' m' true);
        (* and join the old domain without issuing warnings *)
        List.fold_left (fun m k -> D.join m (f k m false)) m xs
    in
    match lval, f.vname, arglist with
    | None, "fopen", _ ->
      D.warn "file handle is not saved!"; m
    | Some lval, "fopen", _ ->
      let f k m w =
        let m = check_overwrite_open k m in
        (match arglist with
         | Const(CStr(filename,_))::Const(CStr(mode,_))::[] ->
           (* M.debug ~category:Analyzer @@ "fopen(\""^filename^"\", \""^mode^"\")"; *)
           D.fopen k loc filename mode m |> split_err_branch lval (* TODO k instead of lval? *)
         | e::Const(CStr(mode,_))::[] ->
           (* ignore(printf "CIL: %a\n" d_plainexp e); *)
           (match ctx.ask (Queries.EvalStr e) with
            | `Lifted filename -> D.fopen k loc filename mode m
            | _ -> D.warn "[Unsound]unknown filename"; D.fopen k loc "???" mode m
           )
         | xs ->
           let args = (String.concat ", " (List.map CilType.Exp.show xs)) in
           M.debug ~category:Analyzer "fopen args: %s" args;
           (* List.iter (fun exp -> ignore(printf "%a\n" d_plainexp exp)) xs; *)
           D.warn @@ "[Program]fopen needs two strings as arguments, given: "^args; m
        )
      in ret_all f lval

    | _, "fclose", [Lval fp] ->
      let f k m w =
        if w then D.reports k [
            false, D.closed,  "closeing already closed file handle "^D.string_of_key k;
            true,  D.opened,  "closeing unopened file handle "^D.string_of_key k
          ] m;
        D.fclose k loc m
      in ret_all f fp
    | _, "fclose", _ ->
      D.warn "fclose needs exactly one argument"; m

    | _, "fprintf", (Lval fp)::_::_ ->
      let f k m w =
        if w then D.reports k [
            false, D.closed,   "writing to closed file handle "^D.string_of_key k;
            true,  D.opened,   "writing to unopened file handle "^D.string_of_key k;
            true,  D.writable, "writing to read-only file handle "^D.string_of_key k;
          ] m;
        m
      in ret_all f fp
    | _, "fprintf", fp::_::_ ->
      (* List.iter (fun exp -> ignore(printf "%a\n" d_plainexp exp)) arglist; *)
      print_query_lv ~msg:"fprintf(?, ...): " (Analyses.ask_of_ctx ctx) fp;
      D.warn "[Program]first argument to printf must be a Lval"; m
    | _, "fprintf", _ ->
      D.warn "[Program]fprintf needs at least two arguments"; m

    | _ -> m

  let startstate v = D.bot ()
  let threadenter ctx lval f args = [D.bot ()]
  let threadspawn ctx lval f args fctx = ctx.local
  let exitstate  v = D.bot ()
end

let _ =
  MCP.register_analysis (module Spec : MCPSpec)
