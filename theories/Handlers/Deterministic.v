(** * Generic total deterministic IO handler *)
From LibTx Require Import
     SLOT.EventTrace
     SLOT.Handler.

From Coq Require Import
     List.

Import ListNotations.

Class DeterministicHandler {PID : Set} (Req : Set) (Ret : Req -> Set) :=
  { det_h_state : Set;
    det_h_chain_rule :  forall (pid : PID) (s : det_h_state) (req : Req), det_h_state * Ret req;
  }.

Global Instance deterministicHandler `{d : DeterministicHandler} : @Handler PID Req Ret :=
  { h_chain_rule s s' te :=
      let (pid, req, ret) := te in
      let (s'_, ret_) := det_h_chain_rule pid s req in
      s' = s'_ /\ ret = ret_;
  }.

From Coq Require
     Classes.EquivDec
     Arith.Peano_dec.

Ltac elim_det H :=
  match type of H with
  | ?s = ?s' /\ ?ret = ?ret' =>
    let Hs := fresh "Hs" in
    let Hret := fresh "Hret" in
    destruct H as [Hret Hs];
    subst s; subst ret;
    clear H
  end.

Module Var.
  Section defs.
    Context {PID T : Set}.

    Inductive var_req_t : Set :=
    | read
    | write : T -> var_req_t.

    Definition var_ret_t req : Set :=
      match req with
      | read => T
      | write _ => True
      end.

    Definition var_step (_ : PID) s req : T * var_ret_t req :=
      match req with
      | read => (s, s)
      | write new => (new, I)
      end.

    Global Instance varHandler : DeterministicHandler var_req_t var_ret_t :=
      { det_h_state := T;
        det_h_chain_rule := var_step;
      }.
  End defs.
End Var.

Module AtomicVar.
  Import EquivDec Peano_dec.

  Section defs.
    Context {PID T : Set} `{@EqDec T eq eq_equivalence}.

    Inductive avar_req_t : Set :=
    | read
    | write : T -> avar_req_t
    | CAS : T -> T -> avar_req_t.

    Definition avar_ret_t req : Set :=
      match req with
      | read => T
      | write _ => True
      | CAS _ _ => bool
      end.

    Definition step (_ : PID) s req : T * avar_ret_t req :=
      match req with
      | read => (s, s)
      | write new => (new, I)
      | CAS old new =>
        if equiv_dec old s then
          (new, true)
        else
          (s, false)
      end.

    Global Instance atomVarHandler : DeterministicHandler avar_req_t avar_ret_t :=
      { det_h_state := T;
        det_h_chain_rule := step;
      }.
  End defs.

  Section tests.
    Goal forall (r1 r2 : nat),
        r1 <> r2 ->
        {{fun _ => True}}
          [I @ r1 <~ read;
           I @ r2 <~ read]
        {{fun s => False}}.
    Proof.
      intros. unfold_ht.
      repeat trace_step Hls.
    Qed.
  End tests.
End AtomicVar.

From LibTx Require
     EqDec
     Storage.

Module KV.
  Import Storage EqDec.

  Section defn.
    (** Parameters:
    - [PID] type of process id
    - [K] type of keys
    - [V] type of values
    - [S] intance of storage container that should implement [Storage] interface
    *)
    Context {PID K V : Set} {S : Set} `{HStore : @Storage K V S} `{HKeq_dec : EqDec K}.

    (** ** Syscall types: *)
    Inductive kv_req_t :=
    | read : K -> kv_req_t
    | delete : K -> kv_req_t
    | write : K -> V -> kv_req_t
    | snapshot.

    (** *** Syscall return types: *)
    Definition kv_ret_t (req : kv_req_t) : Set :=
      match req with
      | read _ => option V
      | delete _ => True
      | write _ _ => True
      | snapshot => S
      end.

    Let TE := @TraceElem PID kv_req_t kv_ret_t.

    Definition step (_ : PID) (s : S) (req : kv_req_t) : S * kv_ret_t req :=
      match req with
      | read k => (s, get k s)
      | write k v => (put k v s, I)
      | delete k => (Storage.delete k s, I)
      | snapshot => (s, s)
      end.

    Global Instance varHandler : DeterministicHandler kv_req_t kv_ret_t :=
      { det_h_state := S;
        det_h_chain_rule := step;
      }.
  End defn.

  (** * Properties *)
  Section Properties.
    Context {PID K V S : Set} `{HStore : @Storage K V S}.
    (* Context {PID K V : Set} {S : Set} `{HStore : @Storage K V S} `{HKeq_dec : EqDec K}. *)

    (* Let ctx := mkCtx PID (@req_t K V) (@ret_t K V S). *)
    (* Let TE := @TraceElem PID (@req_t K V) (@ret_t K V S). *)

    (** Two read syscalls always commute: *)
    Lemma kv_rr_comm : forall (p1 p2 : PID) k1 k2 v1 v2,
        trace_elems_commute (p1 @ v1 <~ read k1) (p2 @ v2 <~ read k2).
    Proof.
      split; intros;
      repeat trace_step H; subst;
      repeat forward s';
      now constructor.
    Qed.

    (** Read and snapshot syscalls always commute: *)
    Lemma kv_rs_comm : forall (p1 p2 : PID) k v s,
        trace_elems_commute (p1 @ v <~ read k) (p2 @ s <~ snapshot).
    Proof.
      split; intros;
      repeat trace_step H; subst;
      repeat forward s';
      repeat constructor.
    Qed.

    (* Lemma kv_read_get : forall (pid : PID) (s : S) (k : K) (v : option V), *)
    (*     s ~[pid @ v <~ read k]~> s -> *)
    (*     v = get k s. *)
    (* Proof. *)
    (*   intros. *)
    (*   cbn in H. *)
    (*   destruct H. *)
    (*   now subst. *)
    (* Qed. TODO *)

    (** Read and write syscalls commute when performed on different keys: *)
    Lemma kv_rw_comm : forall (p1 p2 : PID) k1 k2 v1 v2,
        k1 <> k2 ->
        trace_elems_commute (p1 @ v1 <~ read k1) (p2 @ I <~ write k2 v2).
    Proof with firstorder.
      split; intros; repeat trace_step H0.
      - forward (put k2 v2 s)...
        forward (put k2 v2 s)...
        now apply distinct.
      - forward s...
        + symmetry. now apply distinct.
        + forward (put k2 v2 s)...
    Qed.

    (** Read and delete syscalls commute when performed on different keys: *)
    Lemma kv_rd_comm : forall (p1 p2 : PID) k1 k2 v1,
        k1 <> k2 ->
        trace_elems_commute (p1 @ v1 <~ read k1) (p2 @ I <~ delete k2).
    Proof with firstorder.
      split; intros; repeat trace_step H0.
      - forward (Storage.delete k2 s)...
        forward (Storage.delete k2 s)...
        now apply delete_distinct.
      - forward s...
        + symmetry. now apply delete_distinct.
        + forward (Storage.delete k2 s)...
    Qed.

    (** Write syscalls on different keys generally _don't_ commute! *)
    Example kv_ww_comm : forall (p1 p2 : PID) k1 k2 v1 v2,
        k1 <> k2 ->
        trace_elems_commute (p1 @ I <~ write k1 v1) (p2 @ I <~ write k2 v2).
    Abort.
  End Properties.
End KV.

Module History.
  Section defs.
    Context {PID Event : Set}.

    Definition State : Set := list Event.

    Definition hist_req_t := PID -> Event.

    Definition step (pid : PID) (s : State) (req : hist_req_t) := (req pid :: s, I).

    Global Instance historyHandler : DeterministicHandler hist_req_t (fun _ => True) :=
      { det_h_state := list Event;
        det_h_chain_rule := step;
      }.
  End defs.
End History.

Global Arguments deterministicHandler {_} {_} {_}.
