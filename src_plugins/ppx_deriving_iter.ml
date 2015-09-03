open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

let deriver = "iter"
let raise_errorf = Ppx_deriving.raise_errorf

let parse_options options =
  options |> List.iter (fun (name, expr) ->
    match name with
    | _ -> raise_errorf ~loc:expr.pexp_loc "%s does not support option %s" deriver name)

let argn = Printf.sprintf "a%d"

let rec expr_of_typ typ =
  match typ with
  | _ when Ppx_deriving.free_vars_in_core_type typ = [] -> [%expr fun _ -> ()]
  | [%type: [%t? typ] ref]   -> [%expr fun x -> [%e expr_of_typ typ] !x]
  | [%type: [%t? typ] list]  -> [%expr List.iter [%e expr_of_typ typ]]
  | [%type: [%t? typ] array] -> [%expr Array.iter [%e expr_of_typ typ]]
  | [%type: [%t? typ] option] ->
    [%expr function None -> () | Some x -> [%e expr_of_typ typ] x]
  | { ptyp_desc = Ptyp_constr ({ txt = lid }, args) } ->
    app (Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Prefix deriver) lid)))
        (List.map expr_of_typ args)
  | { ptyp_desc = Ptyp_tuple typs } ->
    [%expr fun [%p ptuple (List.mapi (fun i _ -> pvar (argn i)) typs)] ->
      [%e Ppx_deriving.(fold_exprs seq_reduce
            (List.mapi (fun i typ -> app (expr_of_typ typ) [evar (argn i)]) typs))]];
  | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
    let cases =
      fields |> List.map (fun field ->
        match field with
        | Rtag (label, _, true (*empty*), []) ->
          Exp.case (Pat.variant label None) [%expr ()]
        | Rtag (label, _, false, [typ]) ->
          Exp.case (Pat.variant label (Some [%pat? x]))
                   [%expr [%e expr_of_typ typ] x]
        | Rinherit ({ ptyp_desc = Ptyp_constr (tname, _) } as typ) ->
          Exp.case [%pat? [%p Pat.type_ tname] as x]
                   [%expr [%e expr_of_typ typ] x]
        | _ ->
          raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                       deriver (Ppx_deriving.string_of_core_type typ))
    in
    Exp.function_ cases
  | { ptyp_desc = Ptyp_var name } -> [%expr ([%e evar ("poly_"^name)] : 'a -> unit)]
  | { ptyp_desc = Ptyp_alias (typ, name) } ->
    [%expr fun x -> [%e evar ("poly_"^name)] x; [%e expr_of_typ typ] x]
  | { ptyp_loc } ->
    raise_errorf ~loc:ptyp_loc "%s cannot be derived for %s"
                 deriver (Ppx_deriving.string_of_core_type typ)

let str_of_type ~options ~path ({ ptype_loc = loc } as type_decl) =
  parse_options options;
  let iterator =
    match type_decl.ptype_kind, type_decl.ptype_manifest with
    | Ptype_abstract, Some manifest -> expr_of_typ manifest
    | Ptype_variant constrs, _ ->
      constrs |>
      List.map
        (function
          | { pcd_name = { txt = name' }; pcd_args = Pcstr_tuple argts } ->
            let args = List.mapi (fun i typ -> app (expr_of_typ typ) [evar (argn i)]) argts in
            let result =
              match args with
              | []   -> [%expr ()]
              | args -> Ppx_deriving.(fold_exprs seq_reduce) args
            in
            Exp.case (pconstr name' (List.mapi (fun i _ -> pvar (argn i)) argts)) result
          | { pcd_args = Pcstr_record _ } ->
            raise_errorf ~loc "%s currently doesn't support inline records" deriver) |>
      Exp.function_
    | Ptype_record labels, _ ->
      let fields =
        labels |> List.mapi (fun i { pld_name = { txt = name }; pld_type } ->
          [%expr [%e expr_of_typ pld_type] [%e Exp.field (evar "x") (mknoloc (Lident name))]])
      in
      [%expr fun x -> [%e Ppx_deriving.(fold_exprs seq_reduce) fields]]
    | Ptype_abstract, None ->
      raise_errorf ~loc "%s cannot be derived for fully abstract types" deriver
    | Ptype_open, _        ->
      raise_errorf ~loc "%s cannot be derived for open types" deriver
  in
  let polymorphize = Ppx_deriving.poly_fun_of_type_decl type_decl in
  [Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Prefix deriver) type_decl))
               (polymorphize iterator)]

let sig_of_type ~options ~path type_decl =
  parse_options options;
  let typ = Ppx_deriving.core_type_of_type_decl type_decl in
  let polymorphize = Ppx_deriving.poly_arrow_of_type_decl
                        (fun var -> [%type: [%t var] -> unit]) type_decl in
  [Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix deriver) type_decl))
              (polymorphize [%type: [%t typ] -> unit]))]

let () =
  Ppx_deriving.(register (create deriver
    ~core_type: expr_of_typ
    ~type_decl_str: (fun ~options ~path type_decls ->
      [Str.value Recursive (List.concat (List.map (str_of_type ~options ~path) type_decls))])
    ~type_decl_sig: (fun ~options ~path type_decls ->
      List.concat (List.map (sig_of_type ~options ~path) type_decls))
    ()
  ))
