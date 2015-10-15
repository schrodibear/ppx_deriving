open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

let deriver = "show"
let raise_errorf = Ppx_deriving.raise_errorf

let parse_options options =
  let short = ref false in
  let ignore = ref (object method params = [] method constrs = [] end) in
  options |> List.iter (fun (name, expr) ->
    match name with
    | "short" -> short := Ppx_deriving.Arg.(get_expr ~deriver bool) expr
    | "ignore" -> ignore := Ppx_deriving.Arg.(get_ignores ~deriver) expr
    | _ -> raise_errorf ~loc:expr.pexp_loc "%s does not support option %s" deriver name);
  object method short = !short method ignore = !ignore end

let attr_nobuiltin attrs =
  Ppx_deriving.(attrs |> attr ~deriver "nobuiltin" |> Arg.get_flag ~deriver)

let attr_printer attrs =
  Ppx_deriving.(attrs |> attr ~deriver "printer" |> Arg.(get_attr ~deriver expr))

let attr_polyprinter attrs =
  Ppx_deriving.(attrs |> attr ~deriver "polyprinter" |> Arg.(get_attr ~deriver expr))

let attr_opaque attrs =
  Ppx_deriving.(attrs |> attr ~deriver "opaque" |> Arg.get_flag ~deriver)

let argn = Printf.sprintf "a%d"

let pp_type_of_decl ~options ~path type_decl =
  let opts = parse_options options in
  let typ = Ppx_deriving.core_type_of_type_decl type_decl in
  Ppx_deriving.poly_arrow_of_type_decl
    ~ignore:opts#ignore#params
    (fun var -> [%type: Format.formatter -> [%t var] -> Ppx_deriving_runtime.unit])
    type_decl
    [%type: Format.formatter -> [%t typ] -> Ppx_deriving_runtime.unit]

let show_type_of_decl ~options ~path type_decl =
  let opts = parse_options options in
  let typ = Ppx_deriving.core_type_of_type_decl type_decl in
  Ppx_deriving.poly_arrow_of_type_decl
    ~ignore:opts#ignore#params
    (fun var -> [%type: Format.formatter -> [%t var] -> Ppx_deriving_runtime.unit])
    type_decl
    [%type: [%t typ] -> Ppx_deriving_runtime.string]

let sig_of_type ~options ~path type_decl =
  ignore (parse_options options);
  [Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix "pp") type_decl))
              (pp_type_of_decl ~options ~path type_decl));
   Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix "show") type_decl))
              (show_type_of_decl ~options ~path type_decl))]

let rec expr_of_typ
    ?(opts=object method ignore = (object method params = [] method constrs = [] end) method short = false end)
    quoter
    typ =
  let expr_of_typ = expr_of_typ ~opts quoter in
  match attr_printer typ.ptyp_attributes with
  | Some printer ->
    let printer =
      [%expr (let fprintf = Format.fprintf in [%e printer]) [@ocaml.warning "-26"]]
    in
    [%expr [%e Ppx_deriving.quote quoter printer] fmt]
  | None ->
  if attr_opaque typ.ptyp_attributes then
    [%expr fun _ -> Format.pp_print_string fmt "<opaque>"]
  else
    let format x = [%expr Format.fprintf fmt [%e str x]] in
    let seq start finish fold typ =
      [%expr fun x ->
        Format.fprintf fmt [%e str start];
        ignore ([%e fold] (fun sep x ->
          if sep then Format.fprintf fmt ";@ ";
          [%e expr_of_typ typ] x; true) false x);
        Format.fprintf fmt [%e str finish];]
    in
    match typ with
    | [%type: _] -> [%expr fun _ -> Format.pp_print_string fmt "_"]
    | { ptyp_desc = Ptyp_arrow _ } ->
      [%expr fun _ -> Format.pp_print_string fmt "<fun>"]
    | { ptyp_desc = Ptyp_constr _ } ->
      let builtin = not (attr_nobuiltin typ.ptyp_attributes) in
      begin match builtin, typ with
      | true, [%type: unit]        -> [%expr fun () -> Format.pp_print_string fmt "()"]
      | true, [%type: int]         -> format "%d"
      | true, [%type: int32]
      | true, [%type: Int32.t]     -> format "%ldl"
      | true, [%type: int64]
      | true, [%type: Int64.t]     -> format "%LdL"
      | true, [%type: nativeint]
      | true, [%type: Nativeint.t] -> format "%ndn"
      | true, [%type: float]       -> format "%F"
      | true, [%type: bool]        -> format "%B"
      | true, [%type: char]        -> format "%C"
      | true, [%type: string]
      | true, [%type: String.t]    -> format "%S"
      | true, [%type: bytes]
      | true, [%type: Bytes.t] ->
        [%expr fun x -> Format.fprintf fmt "%S" (Bytes.to_string x)]
      | true, [%type: [%t? typ] ref] ->
        [%expr fun x ->
          Format.pp_print_string fmt "ref (";
          [%e expr_of_typ typ] !x;
          Format.pp_print_string fmt ")"]
      | true, [%type: [%t? typ] list]  -> seq "[@[<hov>"   "@]]" [%expr List.fold_left]  typ
      | true, [%type: [%t? typ] array] -> seq "[|@[<hov>" "@]|]" [%expr Array.fold_left] typ
      | true, [%type: [%t? typ] option] ->
        [%expr
          function
          | None -> Format.pp_print_string fmt "None"
          | Some x ->
            Format.pp_print_string fmt "(Some ";
            [%e expr_of_typ typ] x;
            Format.pp_print_string fmt ")"]
      | true, ([%type: [%t? typ] lazy_t] | [%type: [%t? typ] Lazy.t]) ->
        [%expr fun x ->
          if Lazy.is_val x then [%e expr_of_typ typ] (Lazy.force x)
          else Format.pp_print_string fmt "<not evaluated>"]
      | _, { ptyp_desc = Ptyp_constr ({ txt = lid }, args); ptyp_loc; _ } ->
        let args_pp =
          let arg_kinds =
            match List.find_all (fun (lid', _) -> lid = lid') opts#ignore#constrs with
            | [_, kinds] -> kinds
            | [] -> List.map (fun _ -> `Real) args
            | _ :: _ :: _ ->
              raise_errorf
                ~loc:ptyp_loc
                "%s: ambiguous phantom type parameter specification for type %s"
                deriver
                (String.concat "." @@ Longident.flatten lid)
          in
          if List.(length arg_kinds = length args) then
            List.fold_right2
              (fun typ kind acc ->
                 match kind with
                 | `Real -> [%expr fun fmt -> [%e expr_of_typ typ]] :: acc
                 | `Phantom -> acc)
              args
              arg_kinds
              []
          else
            raise_errorf
              ~loc:ptyp_loc
              "%s: wrong parameter count in phantom type parameter specification for type %s"
              deriver
              (String.concat "." @@ Longident.flatten lid)
        in
        let printer =
          match attr_polyprinter typ.ptyp_attributes with
          | Some printer ->
            [%expr (let fprintf = Format.fprintf in [%e printer]) [@ocaml.warning "-26"]]
          | None ->
            Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Prefix "pp") lid))
        in
        app (Ppx_deriving.quote quoter printer)
            (args_pp @ [[%expr fmt]])
      | _ -> assert false
      end
    | { ptyp_desc = Ptyp_tuple typs } ->
      let args = List.mapi (fun i typ -> app (expr_of_typ typ) [evar (argn i)]) typs in
      [%expr
        fun [%p ptuple (List.mapi (fun i _ -> pvar (argn i)) typs)] ->
        Format.fprintf fmt "(@[<hov>";
        [%e args |> Ppx_deriving.(fold_exprs
                (seq_reduce ~sep:[%expr Format.fprintf fmt ",@ "]))];
        Format.fprintf fmt "@])"]
    | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
      let cases =
        fields |> List.map (fun field ->
          match field with
          | Rtag (label, _, true (*empty*), []) ->
            Exp.case (Pat.variant label None)
                     [%expr Format.pp_print_string fmt [%e str ("`" ^ label)]]
          | Rtag (label, _, false, [typ]) ->
            Exp.case (Pat.variant label (Some [%pat? x]))
                     [%expr Format.fprintf fmt [%e str ("`" ^ label ^ " (@[<hov>")];
                            [%e expr_of_typ typ] x;
                            Format.fprintf fmt "@])"]
          | Rinherit ({ ptyp_desc = Ptyp_constr (tname, _) } as typ) ->
            Exp.case [%pat? [%p Pat.type_ tname] as x]
                     [%expr [%e expr_of_typ typ] x]
          | _ ->
            raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                         deriver (Ppx_deriving.string_of_core_type typ))
      in
      Exp.function_ cases
    | { ptyp_desc = Ptyp_var name } -> [%expr [%e evar ("poly_"^name)] fmt]
    | { ptyp_desc = Ptyp_alias (typ, _) } -> expr_of_typ typ
    | { ptyp_loc } ->
      raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                   deriver (Ppx_deriving.string_of_core_type typ)

let str_of_type ~options ~path ({ ptype_loc = loc } as type_decl) =
  let opts = parse_options options in
  let quoter = Ppx_deriving.create_quoter () in
  let path = Ppx_deriving.path_of_type_decl ~path type_decl in
  let prettyprinter =
    let pp_record labels =
      let fields =
        labels |> List.mapi (fun i { pld_name = { txt = name }; pld_type; pld_attributes } ->
          let field_name = if i = 0 && not opts#short then Ppx_deriving.expand_path ~path name else name in
          let pld_type = {pld_type with ptyp_attributes=pld_attributes@pld_type.ptyp_attributes} in
          [%expr Format.pp_print_string fmt [%e str (field_name ^ " = ")];
          [%e expr_of_typ ~opts quoter pld_type] [%e Exp.field (evar "x") (mknoloc (Lident name))]])
      in
      [%expr
        Format.fprintf fmt "{ @[<hov>";
        [%e fields |> Ppx_deriving.(fold_exprs
              (seq_reduce ~sep:[%expr Format.fprintf fmt ";@ "]))];
        Format.fprintf fmt "@] }"]
    in
    match type_decl.ptype_kind, type_decl.ptype_manifest with
    | Ptype_abstract, Some manifest ->
      [%expr fun fmt -> [%e expr_of_typ ~opts quoter manifest]]
    | Ptype_variant constrs, _ ->
      let cases =
        constrs |>
        List.map
          (fun ({ pcd_name = { txt = name' }; _ } as cd) ->
             let constr_name = if not opts#short then Ppx_deriving.expand_path ~path name' else name' in
             match cd.pcd_args with
            | Pcstr_tuple argts ->
              let args = List.mapi (fun i typ -> app (expr_of_typ ~opts quoter typ) [evar (argn i)]) argts in
              let result =
                match args with
                | []   -> [%expr Format.pp_print_string fmt [%e str constr_name]]
                | [arg] ->
                  [%expr
                    Format.fprintf fmt [%e str ("(@[<hov2>" ^ constr_name ^ "@ ")];
                    [%e arg];
                    Format.fprintf fmt "@])"]
                | args ->
                  [%expr Format.fprintf fmt [%e str ("@[<hov2>" ^  constr_name ^ " (@,")];
                         [%e args |> Ppx_deriving.(fold_exprs
                                                     (seq_reduce ~sep:[%expr Format.fprintf fmt ",@ "]))];
                         Format.fprintf fmt "@])"]
              in
              Exp.case (pconstr name' (List.mapi (fun i _ -> pvar (argn i)) argts)) result
            | Pcstr_record labels ->
              let result =
                [%expr
                  Format.fprintf fmt [%e str ("@[<hov2>" ^  constr_name ^ "@ ")];
                  [%e pp_record labels];
                  Format.fprintf fmt "@]"]
              in
              Exp.case (pconstr name' [[%pat? x]]) result)
      in
      [%expr fun fmt -> [%e Exp.function_ cases]]
    | Ptype_record labels, _ -> [%expr fun fmt x -> [%e pp_record labels]]
    | Ptype_abstract, None ->
      raise_errorf ~loc "%s cannot be derived for fully abstract types" deriver
    | Ptype_open, _        ->
      raise_errorf ~loc "%s cannot be derived for open types" deriver
  in
  let pp_poly_apply =
    Ppx_deriving.poly_apply_of_type_decl
      ~ignore:opts#ignore#params
      type_decl
      (evar (Ppx_deriving.mangle_type_decl (`Prefix "pp") type_decl))
  in
  let stringprinter = [%expr fun x -> Format.asprintf "%a" [%e pp_poly_apply] x] in
  let polymorphize ?sanitize_with ?constrain =
    Ppx_deriving.poly_fun_of_type_decl
      ~ignore:opts#ignore#params
      ?sanitize_with
      ?constrain
      type_decl
  in
  let pp_type = pp_type_of_decl ~options ~path type_decl in
  let strong_pp_type = Ppx_deriving.strong_type_of_type pp_type in
  let show_type = show_type_of_decl ~options ~path type_decl in
  let strong_show_type = Ppx_deriving.strong_type_of_type show_type in
  let pp_var =
    pvar (Ppx_deriving.mangle_type_decl (`Prefix "pp") type_decl) in
  let show_var =
    pvar (Ppx_deriving.mangle_type_decl (`Prefix "show") type_decl) in
  [Vb.mk
     (Pat.constraint_ pp_var strong_pp_type)
     (polymorphize
        ~sanitize_with:(Some quoter)
        ~constrain:(let typ = Ppx_deriving.core_type_of_type_decl type_decl in
                    [%type: Format.formatter -> [%t typ] -> Ppx_deriving_runtime.unit])
        prettyprinter);
   Vb.mk
     (Pat.constraint_ show_var strong_show_type)
     (polymorphize stringprinter)]

let () =
  Ppx_deriving.(register (create deriver
    ~core_type: (Ppx_deriving.with_quoter (fun quoter typ ->
      [%expr fun x -> Format.asprintf "%a" (fun fmt -> [%e expr_of_typ quoter typ]) x]))
    ~type_decl_str: (fun ~options ~path type_decls ->
      [Str.value Recursive (List.concat (List.map (str_of_type ~options ~path) type_decls))])
    ~type_decl_sig: (fun ~options ~path type_decls ->
      List.concat (List.map (sig_of_type ~options ~path) type_decls))
    ()
  ))
