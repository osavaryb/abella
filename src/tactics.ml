(****************************************************************************)
(* Copyright (C) 2007-2008 Gacek                                            *)
(*                                                                          *)
(* This file is part of Abella.                                             *)
(*                                                                          *)
(* Abella is free software: you can redistribute it and/or modify           *)
(* it under the terms of the GNU General Public License as published by     *)
(* the Free Software Foundation, either version 3 of the License, or        *)
(* (at your option) any later version.                                      *)
(*                                                                          *)
(* Abella is distributed in the hope that it will be useful,                *)
(* but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(* GNU General Public License for more details.                             *)
(*                                                                          *)
(* You should have received a copy of the GNU General Public License        *)
(* along with Abella.  If not, see <http://www.gnu.org/licenses/>.          *)
(****************************************************************************)

open Term
open Metaterm
open Unify
open Extensions

(* Variable naming utilities *)

let is_question str =
  str.[0] = '?'
        
let question_var_names terms =
  terms
  |> map_vars_list (fun v -> v.name)
  |> List.find_all is_question
  |> List.unique

let is_capital str =
  match str.[0] with
    | 'A'..'Z' -> true
    | _ -> false
        
let capital_var_names terms =
  terms
  |> map_vars_list (fun v -> v.name)
  |> List.find_all is_capital
  |> List.unique

let free_capital_var_names metaterm =
  let aux_term = capital_var_names in
  let aux_obj obj = aux_term obj.context @ aux_term [obj.term] in
  let rec aux = function
    | True | False -> []
    | Eq(a, b) -> aux_term [a; b]
    | Obj(obj, r) -> aux_obj obj
    | Arrow(a, b) -> aux a @ aux b
    | Binding(binder, bindings, body) -> List.minus (aux body) bindings
    | Or(a, b) -> aux a @ aux b
    | And(a, b) -> aux a @ aux b
    | Pred(p, r) -> aux_term [p]
  in
    List.unique (aux metaterm)

let alist_to_used (_, t) = term_to_pair t

let freshen_clause ~used ?(support=[]) head body =
  let var_names = capital_var_names (head::body) in
  let fresh_names = fresh_alist ~tag:Eigen ~used var_names in
  let raised_names = raise_alist ~support fresh_names in
    (List.map alist_to_used fresh_names @ used,
     replace_term_vars raised_names head,
     List.map (replace_term_vars raised_names) body)

let freshen_def ~used ?(support=[]) head body =
  let var_names = capital_var_names [head] in
  let fresh_names = fresh_alist ~tag:Eigen ~used var_names in
  let raised_names = raise_alist ~support fresh_names in
    (List.map alist_to_used fresh_names,
     replace_term_vars raised_names head,
     replace_metaterm_vars raised_names body)

let term_vars_alist tag terms =
  List.map term_to_pair (find_var_refs tag terms)
    
let metaterm_vars_alist tag metaterm =
  term_vars_alist tag (collect_terms metaterm)
      
(* Freshening for Logic variables uses anonymous names *)
      
let fresh_nameless_alist ~support ids =
  List.map (fun x -> (x, app (fresh ~tag:Logic 0) support)) ids
      
let freshen_nameless_clause ?(support=[]) head body =
  let var_names = capital_var_names (head::body) in
  let fresh_names = fresh_nameless_alist ~support var_names in
  let fresh_head = replace_term_vars fresh_names head in
  let fresh_body = List.map (replace_term_vars fresh_names) body in
    (fresh_head, fresh_body)

let freshen_nameless_def ?(support=[]) head body =
  let var_names = capital_var_names [head] in
  let fresh_names = fresh_nameless_alist ~support var_names in
  let fresh_head = replace_term_vars fresh_names head in
  let fresh_body = replace_metaterm_vars fresh_names body in
    (fresh_head, fresh_body)

let freshen_nameless_bindings ?(support=[]) bindings term =
  replace_metaterm_vars (fresh_nameless_alist ~support bindings) term

(* Object level cut *)

(* obj1 = L2, A |- C
   obj2 = L1 |- A
   result = L2, L1 |- C *)
let object_cut obj1 obj2 =
  if Context.mem obj2.term obj1.context then
    let ctx =
      obj1.context
      |> Context.remove obj2.term
      |> Context.union obj2.context
      |> Context.normalize 
    in
      Obj(context_obj ctx obj1.term, Irrelevant)
  else
    failwith "Needless use of cut"

(* Object level instantiation *)

(* inst t1 with n = t2 *)
let object_inst t1 n t2 =
  if List.mem n (List.map term_to_name (metaterm_support t1)) then
    map_on_objs (map_obj (replace_term_vars ~tag:Nominal [(n, t2)])) t1
  else
    failwith ("Did not find " ^ n)

(* Case analysis *)

type case = {
  bind_state : bind_state ;
  new_vars : (id * term) list ;
  new_hyps : metaterm list ;
}

type stateless_case = {
  stateless_new_vars : (id * term) list ;
  stateless_new_hyps : metaterm list ;
}

let empty_case = { stateless_new_vars = [] ; stateless_new_hyps = [] }

let stateless_case_to_case case =
  { bind_state = get_bind_state () ;
    new_vars = case.stateless_new_vars ;
    new_hyps = case.stateless_new_hyps }

let rec recursive_metaterm_case ~used term =
  match normalize term with
    | True -> Some empty_case
    | False -> None
    | Eq(a, b) ->
        if try_left_unify a b then
          Some empty_case
        else
          None
    | And(left, right) ->
        begin match recursive_metaterm_case ~used left with
          | None -> None
          | Some {stateless_new_vars = vars_left ;
                  stateless_new_hyps = hyps_left } ->
              match recursive_metaterm_case ~used:(vars_left @ used) right with
                | None -> None
                | Some {stateless_new_vars = vars_right ;
                        stateless_new_hyps = hyps_right } ->
                    Some { stateless_new_vars = vars_left @ vars_right ;
                           stateless_new_hyps = hyps_left @ hyps_right }
        end
    | Binding(Exists, ids, body) ->
        let fresh_ids = fresh_alist ~used ~tag:Eigen ids in
        let support = metaterm_support term in
        let raised_ids = raise_alist ~support fresh_ids in
        let fresh_body = replace_metaterm_vars raised_ids body in
        let new_vars = List.map alist_to_used fresh_ids in
        let nested =
          recursive_metaterm_case ~used:(new_vars @ used) fresh_body
        in
          begin match nested with
            | None -> None
            | Some { stateless_new_vars = nested_vars ;
                     stateless_new_hyps = nested_hyps } ->
                Some { stateless_new_vars = new_vars @ nested_vars ;
                       stateless_new_hyps = nested_hyps }
          end
    | Binding(Nabla, ids, body) ->
        let fresh_body = instantiate_nablas ids body in
        recursive_metaterm_case ~used fresh_body
    | _ -> Some {stateless_new_vars = [] ; stateless_new_hyps = [term]}

let rec or_to_list term =
  match term with
    | Or(left, right) -> (or_to_list left) @ (or_to_list right)
    | _ -> [term]

let rec and_to_list term =
  match term with
    | And(left, right) -> (and_to_list left) @ (and_to_list right)
    | _ -> [term]

let predicate_wrapper r psig t =
  let rec aux t =
    match t with
      | True | False | Eq _ | Obj _ -> t
      | Pred(p, _) ->
          if term_sig p = psig then
            Pred(p, reduce_inductive_restriction r)
          else
            t
      | Binding(binding, ids, body) -> Binding(binding, ids, aux body)
      | Or(t1, t2) -> Or(aux t1, aux t2)
      | And(t1, t2) -> And(aux t1, aux t2)
      | Arrow(t1, t2) -> Arrow(t1, aux t2)
  in
    aux t
    
let lift_all ~used nominals =
  used |> List.iter
      (fun (id, term) ->
         if is_free term then
           let new_term = var Eigen id 0 in
             bind term (app new_term nominals))

let case ~used ~clauses ~defs ~global_support term =

  let support = metaterm_support term in
  let initial_bind_state = get_bind_state () in
  
  let def_case ~wrapper term =
    let make_case ~support ~used (head, body) term =
      let fresh_used, head, body =
        freshen_def ~support ~used head body
      in
        if try_left_unify ~used:(fresh_used @ used) head term then
          let bind_state = get_bind_state () in
            (* Names created perhaps by unificiation *)
          let used_head = term_vars_alist Eigen [head] in
          let used_body = metaterm_vars_alist Eigen body in
          let used = List.unique
            (used_head @ used_body @ used)
          in
            match recursive_metaterm_case ~used body with
              | None -> []
              | Some case ->
                  [{ bind_state = bind_state ;
                     new_vars = case.stateless_new_vars @ used ;
                     new_hyps = List.map wrapper case.stateless_new_hyps }]
        else
          []
    in
      defs |> List.flatten_map
          (function
             | Pred(head, _), body ->
                 set_bind_state initial_bind_state ;
                 make_case ~support ~used (head, body) term
             | Binding(Nabla, ids, Pred(head, _)), body ->
                 List.backwards_range 0 (List.length ids) |> List.flatten_map
                     (fun n ->
                        (* n is the number of nablas to be raised *)
                        (* They should be fresh with respect to global_support *)
                        let nominals = fresh_nominals n (pred (app head global_support)) in
                          List.choose n ids |> List.flatten_map
                              (fun raised ->
                                 set_bind_state initial_bind_state ;
                                 let alist = List.combine raised nominals in
                                 let () = lift_all ~used nominals in
                                 let head = replace_term_vars alist head in
                                 let ids = List.minus ids raised in
                                 let inner_bind_state = get_bind_state () in
                                   List.permute (List.length ids) support |> List.flatten_map
                                       (fun permuted ->
                                          set_bind_state inner_bind_state ;
                                          let support = List.minus support permuted in
                                          let alist = List.combine ids permuted in
                                          let head = replace_term_vars alist head in
                                          let body = replace_metaterm_vars alist body in
                                            make_case ~support ~used (head, body) term)))
             | _ -> failwith "Bad head in definition")
  in
          
  let clause_case ~wrapper term =
    clauses |> List.filter_map
        (fun (head, body) ->
           set_bind_state initial_bind_state ;           
           let fresh_used, fresh_head, fresh_body =
             freshen_clause ~support ~used head body
           in
             if try_left_unify ~used:(fresh_used @ used) fresh_head term then
               let new_vars = term_vars_alist Eigen (fresh_head::fresh_body) in
               let bind_state = get_bind_state () in
               let wrapped_body = List.map wrapper fresh_body in
                 set_bind_state initial_bind_state ;
                 Some { bind_state = bind_state ;
                        new_vars = new_vars ;
                        new_hyps = wrapped_body }
             else
               None)
  in
    
  let obj_case obj r =
    let wrapper t =
      Obj(context_obj obj.context t, reduce_inductive_restriction r)
    in
    let clause_cases = clause_case ~wrapper obj.term in
      if Context.is_empty obj.context then
        clause_cases
      else
        let member_case =
          { bind_state = get_bind_state () ;
            new_vars = [] ;
            new_hyps = [obj_to_member obj] }
        in
          member_case :: clause_cases
  in
    
    match term with
      | Obj(obj, r) -> obj_case obj r
      | Pred(_, CoSmaller _) -> failwith "Cannot case analyze hypothesis\
                                          \ with coinductive restriction"
      | Pred(p, r) -> def_case ~wrapper:(predicate_wrapper r (term_sig p)) p
      | Or _ -> List.map stateless_case_to_case
          (List.filter_map (recursive_metaterm_case ~used) (or_to_list term))
      | Eq _
      | And _
      | Binding(Exists, _, _)
      | Binding(Nabla, _, _) ->
          Option.map_default (fun sc -> [stateless_case_to_case sc]) []
            (recursive_metaterm_case ~used term)
      | _ -> invalid_metaterm_arg term
          


(* Induction *)

let rec set_restriction_at res stmt arg =
  match stmt with
    | Arrow(left, right) ->
        if arg = 1 then
          Arrow(set_restriction res left, right)
        else
          Arrow(left, set_restriction_at res right (arg-1))
    | _ -> failwith "Not enough implications in induction"

let induction ind_arg ind_num stmt =
  let rec aux stmt =
    match stmt with
      | Binding(Forall, bindings, body) ->
          let (ih, goal) = aux body in
            (forall bindings ih, forall bindings goal)
      | Binding(Nabla, bindings, body) ->
          let (ih, goal) = aux body in
            (nabla bindings ih, nabla bindings goal)
      | term ->
          let ih = set_restriction_at (Smaller ind_num) term ind_arg in
          let goal = set_restriction_at (Equal ind_num) term ind_arg in
            (ih, goal)
  in
    aux stmt

let coinduction res_num stmt =
  let rec aux stmt =
    match stmt with
      | Binding(Forall, bindings, body) ->
          let (ch, goal) = aux body in
            (forall bindings ch, forall bindings goal)
      | Binding(Nabla, bindings, body) ->
          let (ch, goal) = aux body in
            (nabla bindings ch, nabla bindings goal)
      | Arrow(left, right) ->
          let (ch, goal) = aux right in
            (arrow left ch, arrow left goal)
      | Pred(p, _) ->
          let ch = Pred(p, CoSmaller res_num) in
          let goal = Pred(p, Equal res_num) in
            (ch, goal)
      | _ -> invalid_metaterm_arg stmt
  in
    aux stmt


(* Unfold the current goal *)

let coinductive_wrapper r psig t =
  let rec aux t =
    match t with
      | True | False | Eq _ | Obj _ -> t
      | Pred(p, _) ->
          if term_sig p = psig then
            Pred(p, reduce_coinductive_restriction r)
          else
            t
      | Binding(binding, ids, body) -> Binding(binding, ids, aux body)
      | Or(t1, t2) -> Or(aux t1, aux t2)
      | And(t1, t2) -> And(aux t1, aux t2)
      | Arrow(t1, t2) -> Arrow(t1, aux t2)
  in
    aux t
    
let unfold_defs ~defs goal r =
  let initial_bind_state = get_bind_state () in
  let support = term_support goal in
  let wrapper = coinductive_wrapper r (term_sig goal) in
  let unfold_def ids head body =
    support |> List.permute (List.length ids) |> List.flatten_map
        (fun nominals ->
           let () = set_bind_state initial_bind_state in
           let support = List.minus support nominals in
           let alist = List.combine ids nominals in
           let head = replace_term_vars alist head in
           let head, body = freshen_nameless_def ~support head body in
             match try_right_unify_cpairs head goal with
               | None -> []
               | Some cpairs ->
                   [(get_bind_state (), cpairs, normalize (wrapper body))])
  in
  let result =
    defs |> List.flatten_map
        (fun (head, body) ->
           match head with
             | Pred(head, _) -> unfold_def [] head body
             | Binding(Nabla, ids, Pred(head, _)) -> unfold_def ids head body
             | _ -> failwith "Bad head in definition")
  in
    set_bind_state initial_bind_state ;
    result

let unfold ~defs goal =
  match goal with
    | Pred(goal, r) ->
        (* Find the first body without lingering conflict pairs *)
        let rec select_non_cpair list =
          match list with
            | (bind_state, [], body)::_ -> set_bind_state bind_state; body
            | _::rest -> select_non_cpair rest
            | [] -> failwith "No matching definitions"
        in
          select_non_cpair (unfold_defs ~defs goal r)
    | _ -> failwith "Can only unfold definitions"
      

(* Search *)

exception SearchSuccess

let iter_keep_state f list =
  let state = get_bind_state () in
    List.iter (fun x -> f x ; set_bind_state state) list

let try_unify_cpairs cpairs =
  List.for_all (curry try_right_unify) cpairs


(* Depth is decremented only when unfolding clauses and definitions since
   only these can cause infinite search *)
(* Each aux search returns () on failure and calls sc () on success. This
   allows for effective backtracking. sc means success continuation. *)

let search ~depth:n ~hyps ~clauses ~defs goal =
  
  let rec clause_aux n context goal ~sc =
    let support = term_support goal in
    let freshen_clause = curry (freshen_nameless_clause ~support) in
    let fresh_clauses = List.map freshen_clause clauses in
    let wrap body = List.map (fun t -> {context=context; term=t}) body in
      fresh_clauses |> iter_keep_state
          (fun (head, body) ->
             match try_right_unify_cpairs head goal with
               | None -> ()
               | Some cpairs ->
                   obj_aux_conj (n-1) (wrap body)
                     ~sc:(fun () -> if try_unify_cpairs cpairs then sc ()))
          
  and obj_aux n goal ~sc =
    let goal = normalize_obj goal in
      (* Check hyps for derivability *)
      hyps |> filter_objs |>
          iter_keep_state (fun obj -> if derivable goal obj then sc ()) ;

      (* Check context *)
      if not (Context.is_empty goal.context) then
        metaterm_aux n (obj_to_member goal) ~sc ;

      (* Backchain *)
      if n > 0 then clause_aux n goal.context goal.term ~sc

  and obj_aux_conj n goals ~sc =
    match goals with
      | [] -> sc ()
      | g::gs -> obj_aux n g ~sc:(fun () -> obj_aux_conj n gs ~sc)

  and metaterm_aux n goal ~sc =
    hyps |> iter_keep_state
        (fun hyp ->
           match hyp, goal with
             | Pred(_, CoSmaller i), Pred(_, CoSmaller j) when i = j ->
                 if try_meta_right_permute_unify goal hyp then sc ()
             | Pred(_, CoSmaller i), _ -> ()
             | _ -> if try_meta_right_permute_unify goal hyp then sc ()) ;
      
    match goal with
      | True -> sc ()
      | Eq(left, right) -> if try_right_unify left right then sc ()
      | Or(left, right) ->
          metaterm_aux n left ~sc ; metaterm_aux n right ~sc
      | And(left, right) ->
          metaterm_aux n left ~sc:(fun () -> metaterm_aux n right ~sc)
      | Binding(Exists, bindings, body) ->
          let support = metaterm_support goal in
          let term = freshen_nameless_bindings ~support bindings body in
            metaterm_aux n term ~sc
      | Binding(Nabla, ids, body) ->
          let body = instantiate_nablas ids body in
            metaterm_aux n body ~sc
      | Obj(obj, _) -> obj_aux n obj ~sc
      | Pred(p, r) -> if n > 0 then def_aux n p r ~sc
      | _ -> ()

  and def_aux n goal r ~sc =
    unfold_defs ~defs goal r |> iter_keep_state
        (fun (state, cpairs, body) ->
           set_bind_state state ;
           metaterm_aux (n-1) body
             ~sc:(fun () -> if try_unify_cpairs cpairs then sc ()))
        
  in
    try
      metaterm_aux n goal ~sc:(fun () -> raise SearchSuccess) ;
      false
    with SearchSuccess -> true
      
(* Apply one statement to a list of other statements *)

let check_restrictions formal actual =
  List.iter2 (fun fr ar -> match fr, ar with
                | Smaller i, Smaller j when i = j -> ()
                | Equal i, Smaller j when i = j -> ()
                | Equal i, Equal j when i = j -> ()
                | Irrelevant, _ -> ()
                | _ -> failwith "Inductive restriction violated")
    formal actual

let rec map_args f t =
  match t with
    | Arrow(left, right) ->
        (f left) :: (map_args f right)
    | _ -> []
        
let some_term_to_restriction t =
  match t with
    | None -> Irrelevant
    | Some t -> term_to_restriction t

let apply_arrow term args =
  let () = check_restrictions
    (map_args term_to_restriction term)
    (List.map some_term_to_restriction args)
  in
  let context_pairs = ref [] in
  let obligations = ref [] in
  let result =
    List.fold_left
      (fun term arg ->
         match term, arg with
           | Arrow(Obj(left, _), right), Some Obj(arg, _) ->
               context_pairs := (left.context, arg.context)::!context_pairs ;
               right_unify left.term arg.term ;
               right
           | Arrow(left, right), Some arg ->
               meta_right_unify left arg ;
               right
           | Arrow(left, right), None ->
               obligations := left::!obligations ;
               right
           | _ -> failwith "Too few implications in application")
      term
      args
  in
    Context.reconcile !context_pairs ;
    (normalize result, !obligations)
      
let apply ?(used_nominals=[]) term args =
  let support =
    args
    |> List.flatten_map (Option.map_default metaterm_support [])
    |> List.unique
    |> fun s -> List.minus s used_nominals
  in
    match term with
      | Binding(Forall, bindings, Binding(Nabla, nablas, body)) ->
          let n = List.length nablas in
            support |> List.permute n |> List.find_some
                (fun nominals ->
                   try_with_state ~fail:None
                     (fun () ->
                        let support = List.minus support nominals in
                        let raised_body =
                          freshen_nameless_bindings ~support bindings body
                        in
                        let alist = List.combine nablas nominals in
                        let permuted_body =
                          replace_metaterm_vars alist raised_body
                        in
                          Some (apply_arrow permuted_body args)))
                    
      | Binding(Forall, bindings, body) ->
          apply_arrow (freshen_nameless_bindings ~support bindings body) args
            
      | Arrow _ ->
          apply_arrow term args

      | term when List.length args = 0 -> (term, [])
            
      | _ -> failwith
          ("Structure of applied term must be a " ^
             "substructure of the following.\n" ^
             "forall A1 ... Ai, nabla z1 ... zj, H1 -> ... -> Hk -> C")
            
let rec ensure_unique_nominals lst =
  match lst with
    | [] -> ()
    | x::xs ->
        if is_nominal x && not (List.mem x xs) then
          ensure_unique_nominals xs
        else
          failwith "Invalid instantiation for nabla variable"

let take_from_binders binders withs =
  let withs' = List.find_all (fun (x,t) -> List.mem x binders) withs in
  let binders' = List.remove_all (fun x -> List.mem_assoc x withs) binders in
    (binders', withs')
            
let rec instantiate_withs term withs =
  match term with
    | Binding(Forall, binders, body) ->
        let binders', withs' = take_from_binders binders withs in
        let body, used_nominals =
          instantiate_withs (replace_metaterm_vars withs' body) withs
        in
          (forall binders' body, used_nominals)
    | Binding(Nabla, binders, body) ->
        let binders', withs' = take_from_binders binders withs in
        let nominals = List.map snd withs' in
        let support = metaterm_support body in
          ensure_unique_nominals nominals ;
          if List.exists (fun x -> List.mem x support) nominals then
            failwith "Invalid instantiation for nabla variable" ;
          let body, used_nominals =
            instantiate_withs (replace_metaterm_vars withs' body) withs
          in
            (nabla binders' body, nominals @ used_nominals)
    | _ -> (term, [])

let apply_with term args withs =
  let term, used_nominals = instantiate_withs term withs in
    apply term args ~used_nominals
  
