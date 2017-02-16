(*
 * Copyright (c) 2017 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

type t = {
  tlen : int;
  coff : int;
  cbuf : Cstruct.t;
}

let chunk_size = 256

let create ?(len=chunk_size) () =
  { tlen = len; coff = 0; cbuf = Cstruct.create len }

let to_cstruct t = Cstruct.set_len t.cbuf t.coff

let left t = t.tlen - t.coff

let used t = t.coff

let grow len t =
  let tlen = t.tlen + len in
  let cbuf = Cstruct.append t.cbuf (Cstruct.create len) in
  { t with tlen; cbuf }

let guard_space len t =
  if (left t) >= len then t else grow (max len chunk_size) t

let shift n t = { t with coff = t.coff + n }

let reserve n t = shift n t

let put_uint8 b t =
  let t = guard_space 1 t in
  Cstruct.set_uint8 t.cbuf t.coff b;
  shift 1 t

let put_bool b t =
  let x = if b then 1 else 0 in
  put_uint8 x t

let put_uint32 w t =
  let t = guard_space 4 t in
  Cstruct.BE.set_uint32 t.cbuf t.coff w;
  shift 4 t

let put_string s t =
  let len = String.length s in
  let t = put_uint32 (Int32.of_int len) t in
  let t = guard_space len t in
  Cstruct.blit_from_string s 0 t.cbuf t.coff len;
  shift len t

let put_cstring s t =
  let len = Cstruct.len s in
  let t = put_uint32 (Int32.of_int len) t in
  let t = guard_space len t in
  Cstruct.blit s 0 t.cbuf t.coff len;
  shift len t

let put_id id buf =
  put_uint8 (Ssh.message_id_to_int id) buf

let put_raw buf t =
  let len = Cstruct.len buf in
  let t = guard_space len t in
  Cstruct.blit buf 0 t.cbuf t.coff len;
  shift len t

let put_random len t =
  put_raw (Nocrypto.Rng.generate len) t

let put_nl nl t =
  put_string (String.concat "," nl) t

let put_mpint mpint t =
  let mpbuf = Nocrypto.Numeric.Z.to_cstruct_be mpint in
  let mplen = Cstruct.len mpbuf in
  let t =
    if mplen > 0 &&
       ((Cstruct.get_uint8 mpbuf 0) land 0x80) <> 0 then
      put_uint32 (Int32.of_int (succ mplen)) t |>
      put_uint8 0
    else
      put_uint32 (Int32.of_int mplen) t
  in
  put_raw mpbuf t

let put_key (rsa : Nocrypto.Rsa.pub) t =
  Nocrypto.Rsa.(put_string "ssh-rsa" t |>
                put_mpint rsa.e |>
                put_mpint rsa.n)

let put_kex kex t =
  let open Ssh in
  let nll = [ kex.kex_algorithms;
              kex.server_host_key_algorithms;
              kex.encryption_algorithms_ctos;
              kex.encryption_algorithms_stoc;
              kex.mac_algorithms_ctos;
              kex.mac_algorithms_stoc;
              kex.compression_algorithms_ctos;
              kex.compression_algorithms_stoc;
              kex.languages_ctos;
              kex.languages_stoc; ]
  in
  List.fold_left (fun buf nl -> put_nl nl buf) (create ()) nll |>
  put_bool kex.first_kex_packet_follows |>
  put_uint32 Int32.zero

let buf_of_key rsa =
  put_key rsa (create ()) |> to_cstruct

let buf_of_kex_pkt kex =
  put_id Ssh.SSH_MSG_KEXINIT (create ()) |>
  put_kex kex |> to_cstruct

let encode_message msg =
  let open Ssh in
  let unimplemented () = failwith "implement me" in
  let put_id id = put_id id (create ()) in
  let buf = match msg with
    | Ssh_msg_disconnect (code, desc, lang) ->
      put_id SSH_MSG_DISCONNECT |>
      put_uint32 code |>
      put_string desc |>
      put_string lang
    | Ssh_msg_ignore s ->
      put_id SSH_MSG_IGNORE |>
      put_string s
    | Ssh_msg_unimplemented x ->
      put_id SSH_MSG_UNIMPLEMENTED |>
      put_uint32 x
    | Ssh_msg_debug (always_display, message, lang) ->
      put_id SSH_MSG_DEBUG |>
      put_bool always_display |>
      put_string message |>
      put_string lang
    | Ssh_msg_service_request s ->
      put_id SSH_MSG_SERVICE_REQUEST |>
      put_string s
    | Ssh_msg_service_accept s ->
      put_id SSH_MSG_SERVICE_ACCEPT |>
      put_string s
    | Ssh_msg_kexinit kex ->
      put_id SSH_MSG_KEXINIT |>
      put_kex kex
    | Ssh_msg_newkeys ->
      put_id SSH_MSG_NEWKEYS
    | Ssh_msg_kexdh_init e ->
      put_id SSH_MSG_KEXDH_INIT |>
      put_mpint e
    | Ssh_msg_kexdh_reply (k_s, f, hsig) ->
      put_id SSH_MSG_KEXDH_REPLY |>
      put_key k_s |>
      put_mpint f |>
      put_cstring hsig
    | Ssh_msg_userauth_request _ -> unimplemented ()
    | Ssh_msg_userauth_failure (nl, psucc) ->
      put_id SSH_MSG_USERAUTH_FAILURE |>
      put_nl nl |>
      put_bool psucc
    | Ssh_msg_userauth_success ->
      put_id SSH_MSG_USERAUTH_SUCCESS
    | Ssh_msg_userauth_banner (message, lang) ->
      put_id SSH_MSG_USERAUTH_BANNER |>
      put_string message |>
      put_string lang
    | Ssh_msg_global_request -> unimplemented ()
    | Ssh_msg_request_success -> unimplemented ()
    | Ssh_msg_request_failure ->
      put_id SSH_MSG_REQUEST_FAILURE
    | Ssh_msg_channel_open -> unimplemented ()
    | Ssh_msg_channel_open_confirmation -> unimplemented ()
    | Ssh_msg_channel_open_failure ->
      put_id SSH_MSG_CHANNEL_OPEN_FAILURE
    | Ssh_msg_channel_window_adjust (channel, n) ->
      put_id SSH_MSG_CHANNEL_WINDOW_ADJUST |>
      put_uint32 channel |>
      put_uint32 n
    | Ssh_msg_channel_data -> unimplemented ()
    | Ssh_msg_channel_extended_data -> unimplemented ()
    | Ssh_msg_channel_eof channel ->
      put_id SSH_MSG_CHANNEL_EOF |>
      put_uint32 channel
    | Ssh_msg_channel_close channel ->
      put_id SSH_MSG_CHANNEL_CLOSE |>
      put_uint32 channel
    | Ssh_msg_channel_request -> unimplemented ()
    | Ssh_msg_channel_success channel ->
      put_id SSH_MSG_CHANNEL_SUCCESS |>
      put_uint32 channel
    | Ssh_msg_channel_failure channel ->
      put_id SSH_MSG_CHANNEL_FAILURE |>
      put_uint32 channel
  in
  to_cstruct buf