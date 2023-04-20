(** An analysis specification for didactic purposes. *)

open Prelude.Ana
open Analyses

module Signs =
struct
  include Printable.StdLeaf

  type t = Neg | Zero | Pos [@@deriving eq, ord, hash, to_yojson]
  let name () = "signs"
  let show x = match x with
    | Neg -> "-"
    | Zero -> "0"
    | Pos -> "+"

  include Printable.SimpleShow (struct
      type nonrec t = t
      let show = show
    end)

  (* TODO: An attempt to abstract integers, but it's just a little wrong... -- DONE *)
  let of_int i =
    if Z.compare i Z.zero < 0 then Neg
    else if Z.compare i Z.zero > 0 then Pos
    else Zero

  let lt x y = match x, y with
    | Neg, Pos | Neg, Zero | Zero, Pos -> true (* TODO: Maybe something missing? -- DONE *)
    | _ -> false
end

(* Now we turn this into a lattice by adding Top and Bottom elements.
 * We then lift the above operations to the lattice. *)
module SL =
struct
  (* include Lattice.Flat (Signs) (Printable.DefaultNames) *)
  include SetDomain.FiniteSet (Signs) (
    struct
      type t = Signs.t
      let elems = [Signs.Neg; Signs.Zero; Signs.Pos]
    end
    )
    
  (* let of_int i = `Lifted (Signs.of_int i) *)
  let of_int i = singleton (Signs.of_int i)

  (* let lt x y = match x, y with
    | `Lifted x, `Lifted y -> Signs.lt x y
     | _ -> false *)
  let lt x y = 
    let list = elements x in
    let rec lt' x y = match x, y with
      | x::xs, y -> (if for_all (Signs.lt x) y = true
          then lt' xs y
        else
          false)
      | [], y -> true in
    lt' list y
end

module Spec : Analyses.MCPSpec =
struct
  let name () = "signs"

  (* Map of integers variables to our signs lattice. *)
  module D = MapDomain.MapBot (Basetype.Variables) (SL)
  module C = D

  let startstate v = D.bot ()
  let exitstate = startstate

  include Analyses.IdentitySpec

  (* This should now evaluate expressions. *)
  let eval (d: D.t) (exp: exp): SL.t = match exp with
    | Const (CInt (i, _, _)) -> SL.of_int i (* TODO: Fix me! -- DONE *)
    | Lval (Var x, NoOffset) -> D.find x d
    | _ -> SL.top ()


  (* Transfer functions: we only implement assignments here.
   * You can leave this code alone... *)
  let assign ctx (lval:lval) (rval:exp) : D.t =
    let d = ctx.local in
    match lval with
    | (Var x, NoOffset) when not x.vaddrof -> D.add x (eval d rval) d
    | _ -> D.top ()


  (* Here we return true if we are absolutely certain that an assertion holds! *)
  let assert_holds (d: D.t) (e:exp) = match e with
    | BinOp (Lt, e1, e2, _) -> SL.lt (eval d e1) (eval d e2)
    | _ -> false

  (* We should now provide this information to Goblint. Assertions are integer expressions,
   * so we implement here a response to EvalInt queries.
   * You should definitely leave this alone... *)
  let query ctx (type a) (q: a Queries.t): a Queries.result =
    let open Queries in
    match q with
    | EvalInt e when assert_holds ctx.local e ->
      let ik = Cilfacade.get_ikind_exp e in
      ID.of_bool ik true
    | _ -> Result.top q
end

let _ =
  MCP.register_analysis (module Spec : MCPSpec)
