(*
 * This file is part of Baardskeerder.
 *
 * Copyright (C) 2011 Incubaid BVBA
 *
 * Baardskeerder is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Baardskeerder is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Baardskeerder.  If not, see <http://www.gnu.org/licenses/>.
 *)

open Base
open Tree
open Log
open Entry
open Slab
open Commit
open Catchup


module DBX(L:LOG) = struct

  let (>>=) = L.bind
  and return = L.return

  type tx = { log: L.t; slab: Slab.t; 
              mutable cactions: caction list}

  module DBL = DB(L)
  module CaL = Catchup(L)

  let get tx k = DBL._get tx.log tx.slab k

  let set tx k v = 
    let vpos = Inner (Slab.length tx.slab) in
    DBL._set tx.log tx.slab k v >>= fun _ ->
    let a = CSet (k, vpos) in
    let () = tx.cactions <- a :: tx.cactions in
    return ()

  let delete tx k = 
    DBL._delete tx.log tx.slab k >>= fun _ ->
    let a = CDelete k in
    let () = tx.cactions <- a :: tx.cactions in
    return ()


  let with_tx ?(inc=Time.next_major) log f = 
    let now = L.now log in
    let fut = inc now in
    let slab = Slab.make fut in
    let tx = {log;slab;cactions = []} in
    f tx >>= fun () ->
    let root = Slab.length tx.slab -1 in
    let previous = L.last log in
    let pos = Inner root in
    let lookup = pos in
    let commit = make_commit ~pos ~previous ~lookup fut (List.rev tx.cactions) in
    let c = Commit commit in
    let _ = Slab.add tx.slab c in
    (* let slab' = slab in *)
    let slab' = Slab.compact tx.slab in 
    L.write log slab'




  let log_update (log:L.t) ?(diff = true) (f: tx -> unit L.m) =
    let _find_lookup () = 
      let pp = L.last log in
      L.read log pp >>= function 
        | Commit lc -> 
          let lu = if diff 
            then Commit.get_pos lc 
            else Commit.get_lookup lc
          in return lu
        | NIL -> return pp
        | e -> failwith (Printf.sprintf "log_update: %s is not commit" (entry2s e))
    in
    let now = L.now log in
    let fut = if diff then Time.next_major now else now in

    let slab = Slab.make fut in
    let tx = {log;slab; cactions = []} in
    
    _find_lookup () >>= fun lookup ->
    f tx >>= fun () ->
    let root = Slab.length tx.slab -1 in
    let previous = L.last log in
    let pos = Inner root in
    let commit = make_commit ~pos ~previous ~lookup fut (List.rev tx.cactions) in
    let c = Commit commit in
    let _ = Slab.add tx.slab c in
    let slab' = Slab.compact tx.slab in
    L.write log slab'

  let commit_last (log:L.t) =
    let pp = L.last log in
    (L.read log pp >>= function
      | Commit lc -> L.return lc
      | e -> failwith (Printf.sprintf "_read_commit: %s is not commit" (entry2s e))
    ) >>= fun lc ->
    let time = Commit.get_time lc in
    let slab = Slab.make time in
    let tx = {log;slab;cactions = []} in
    let pos = Commit.get_pos lc in
    let previous = Commit.get_previous lc in
    let lookup = pos in
    let cactions = Commit.get_cactions lc in
    let commit = make_commit ~pos ~previous ~lookup time cactions in
    let c = Commit commit in
    let _ = Slab.add tx.slab c in
    L.write log slab
    
  let last_update (log:L.t) =
    let pp = L.last log in
    L.read log pp >>= function
      | Commit lc ->
        let cas = Commit.get_cactions lc in
        let time = Commit.get_time lc in
        let i = Time.major_of time in
        CaL.translate_cactions log cas >>= fun actions ->
        L.return (Some (i, actions))
      | NIL -> L.return None
      | e -> failwith (Printf.sprintf "last_update: %s should be commit" (entry2s e))
        
end
