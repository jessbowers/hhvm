(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open ServerEnv
open Utils

module RP = Relative_path

let output_json oc el =
  let errors_json = List.map el Lint.to_json in
  let res =
    Hh_json.JSON_Object [
        "errors", Hh_json.JSON_Array errors_json;
        "version", Hh_json.JSON_String Build_id.build_id_ohai;
    ] in
  output_string oc (Hh_json.json_to_string res);
  flush stderr

let output_text oc el =
  (* Essentially the same as type error output, except that we only have one
   * message per error, and no additional 'typing reasons' *)
  if el = []
  then output_string oc "No lint errors!\n"
  else begin
    let sl = List.map el Lint.to_string in
    List.iter sl begin fun s ->
      Printf.fprintf oc "%s\n%!" s;
    end
  end;
  flush oc

let lint tcopt _acc fnl =
  List.fold_left fnl ~f:begin fun acc fn ->
    let errs, () =
      Lint.do_ begin fun () ->
        Errors.ignore_ begin fun () ->
          Linting_service.lint tcopt fn
            (Sys_utils.cat (Relative_path.to_absolute fn))
        end
      end in
    errs @ acc
  end ~init:[]

let lint_and_filter tcopt code acc fnl =
  let lint_errs = lint tcopt acc fnl in
  List.filter lint_errs (fun err -> Lint.get_code err = code)

let lint_all genv env code =
  let next = compose
    (fun lst -> lst |> List.map ~f:(RP.create RP.Root) |> Bucket.of_list)
    (genv.indexer FindUtils.is_php) in
  let errs = MultiWorker.call
    genv.workers
    ~job:(lint_and_filter env.tcopt code)
    ~merge:List.rev_append
    ~neutral:[]
    ~next in
  List.map errs Lint.to_absolute

let go genv env fnl =
  let fnl = List.map fnl (Relative_path.create Relative_path.Root) in
  let errs =
    if List.length fnl > 10
    then
      MultiWorker.call
        genv.workers
        ~job:(lint env.tcopt)
        ~merge:List.rev_append
        ~neutral:[]
        ~next:(MultiWorker.next genv.workers fnl)
    else
      lint env.tcopt [] fnl in
  let errs = List.sort begin fun x y ->
    Pos.compare (Lint.get_pos x) (Lint.get_pos y)
  end errs in
  List.map errs Lint.to_absolute
