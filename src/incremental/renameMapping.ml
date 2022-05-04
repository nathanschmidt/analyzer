open Cil

module IncrementallyUpdatedVarinfoMap = Hashtbl.Make (CilType.Varinfo)

(*Mapps a varinfo to its updated name*)
let renamedVarinfoMap: string IncrementallyUpdatedVarinfoMap.t ref = ref (IncrementallyUpdatedVarinfoMap.create 100)

let get_old_or_updated_varinfo_name (old_varinfo: varinfo) = 
  let r: string option = IncrementallyUpdatedVarinfoMap.find_opt !renamedVarinfoMap old_varinfo in
  Option.value r ~default:old_varinfo.vname

let store_update_varinfo_name (old_varinfo: varinfo) (new_name: string) =
  Printf.printf "Storing renamed name: %s -> %s\n" old_varinfo.vname new_name;
  IncrementallyUpdatedVarinfoMap.add !renamedVarinfoMap old_varinfo new_name

(*
  Incremental rename aware version of show. Returns the renamed name of the varinfo if it has been updated by an incremental build, or vname if nothing has changed.

  Dev Note: Putting this into CilType.Varinfo results in a cyclic dependency. It should not be put into CilType anyway, as CilType only defines types based on the types themselves, not implement any logic based on other components outside its own definitions. So I think it's cleaner this way.
*)
let show_varinfo (varinfo: varinfo) = 
  Printf.printf "Accessing renamed: %s -> %s\n" varinfo.vname (get_old_or_updated_varinfo_name varinfo);
  get_old_or_updated_varinfo_name varinfo

(*in original Cil v.vname is hardcoded*)
let pVDeclImpl () (v:varinfo) (pType) (pAttrs) =
  (* First the storage modifiers *)
  Pretty.(text (if v.vinline then "__inline " else "")
    ++ d_storage () v.vstorage
    ++ (pType (Some (Pretty.text (show_varinfo v))) () v.vtype)
    ++ Pretty.text " "
    ++ pAttrs () v.vattr)

class incremental_printer : Cil.cilPrinter = object(self)
    inherit Cil.defaultCilPrinterClass 
    method pVar (v:varinfo) = Pretty.text (show_varinfo v)
    
      (* variable declaration *)
    method pVDecl () (v:varinfo) = pVDeclImpl () v self#pType self#pAttrs
end;;

class plain_incremental_printer : Cil.cilPrinter = object(self)
  inherit Cil.plainCilPrinterClass 
  method pVar (v:varinfo) = Pretty.text (show_varinfo v)

  method pVDecl () (v:varinfo) = pVDeclImpl () v self#pType self#pAttrs
end;;

let incremental_aware_printer = new incremental_printer
let plain_incremental_aware_printer = new plain_incremental_printer

let d_exp () e = 
  let _ = Pretty.printf "Printing Exp: %a\n" (printExp incremental_aware_printer) e in
  let _ = match e with
    | BinOp (_, exp1, exp2, _) ->
      ignore@@Pretty.printf "BinOp: %a and %a\n" (printExp incremental_aware_printer) exp1 (printExp incremental_aware_printer) exp2;
      Pretty.printf "%s\n" (Printexc.get_callstack 15 |> Printexc.raw_backtrace_to_string);
    | _ -> 
      Pretty.printf ""; 
    in
    
  printExp incremental_aware_printer () e

let d_lval () l = printLval incremental_aware_printer () l

let d_stmt () s = printStmt incremental_aware_printer () s

(* A hack to allow forward reference of d_exp. Copy from Cil. *)
let pd_exp : (unit -> exp -> Pretty.doc) ref =
  ref (fun _ -> failwith "")

let _ = pd_exp := d_exp

let pd_lval : (unit -> lval -> Pretty.doc) ref = ref (fun _ -> failwith "")
let _ = pd_lval := d_lval

let pd_stmt : (unit -> stmt -> Pretty.doc) ref = ref (fun _ -> failwith "")
let _ = pd_stmt := d_stmt

(*Fixme: Im a copy of Cil.dn_obj because i couldnt figure out why I couldn't access Cil.dn_obj*)
let dn_obj (func: unit -> 'a -> Pretty.doc) : (unit -> 'a -> Pretty.doc) =
  begin
    (* construct the closure to return *)
    let theFunc () (obj:'a) : Pretty.doc =
    begin
      let prevStyle = !lineDirectiveStyle in
      lineDirectiveStyle := None;
      let ret = (func () obj) in    (* call underlying printer *)
      lineDirectiveStyle := prevStyle;
      ret
    end in
    theFunc
  end

let dn_exp = (dn_obj d_exp)

let dn_lval = (dn_obj d_lval)

let dn_stmt = (dn_obj d_stmt)