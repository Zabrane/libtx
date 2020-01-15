(** This module contains a minimalistic implementation of separation logic *)
Require Coq.Vectors.Fin.
Require Coq.Vectors.Vector.
Module Fin := Coq.Vectors.Fin.
Module Vec := Coq.Vectors.Vector.

Module IOHandler.
  Variable N_actors : nat.

  Definition AID : Set := Fin.t N_actors.

  Inductive HandlerRet {req_t state_t : Type} (req : req_t) {rep_t : req_t -> Set} : Type :=
  | r_return : forall (reply : rep_t req)
                 (state' : state_t)
               , HandlerRet req
  | r_stall : HandlerRet req.

  Record t : Type :=
    {
      h_state : Set;
      h_req : Set;
      h_ret : h_req -> Set;
      (* Nondeterministic: *)
      h_initial_state : h_state -> Prop;
      (* Nondeterministic: *)
      h_eval : forall (state : h_state)
                 (aid : AID)
                 (req : h_req)
                 (ret : @HandlerRet h_req h_state req h_ret)
               , Prop;
    }.

  Section Composition.
    Definition compose_state h1 h2 : Set :=
      h_state h1 * h_state h2.

    Definition compose_req h1 h2 : Set :=
      h_req h1 + h_req h2.

    Hint Transparent compose_state.

    Definition compose_initial_state h1 h2 state :=
      h1.(h_initial_state) (fst state) /\ h2.(h_initial_state) (snd state).

    Hint Transparent compose_initial_state.

    Definition compose_ret_t (h1 h2 : t) (req : compose_req h1 h2) : Set :=
      match req with
      | inl l => h1.(h_ret) l
      | inr r => h2.(h_ret) r
      end.

    Hint Transparent compose_ret_t.

    Definition ComposeHandlerRet h1 h2 req :=
      @HandlerRet (compose_req h1 h2)
                  (compose_state h1 h2)
                  req
                  (compose_ret_t h1 h2).

    Definition compose_eval h1 h2
               (state : compose_state h1 h2)
               (aid : AID)
               req
               (ret : ComposeHandlerRet h1 h2 req) : Prop.
      refine (
          (let (s1, s2) := state in
           match req as req' return (req = req' -> Prop) with
           | inl req' => fun H => h1.(h_eval) s1 aid req' _
           | inr req' => fun H => h2.(h_eval) s2 aid req' _
           end) (eq_refl req));
        subst;
        destruct ret;
        try simpl in reply;
        constructor; assumption.
    Defined.

    Definition compose (h1 h2 : t) : t :=
      {| h_state         := compose_state h1 h2;
         h_req           := compose_req h1 h2;
         h_ret           := compose_ret_t h1 h2;
         h_initial_state := compose_initial_state h1 h2;
         h_eval          := compose_eval h1 h2;
      |}.
  End Composition.

  Variable H : t.

  (* TODO: Emulate async requests via list (for TCP) or bag (for UDP)
  of outgoing messages in the actor's state *)

  CoInductive Actor {T : t} : Type :=
  | a_sync1 : forall (pending_io : T.(h_req))
                (continuation : T.(h_ret) pending_io -> Actor)
              , Actor
  | a_sync2 : forall (pending_io : T.(h_req))
                (continuation : T.(h_ret) pending_io -> Actor)
              , Actor
  | a_dead : Actor.

  Definition Actors := Vec.t (@Actor H) N_actors.

  Definition Trace := list H.(h_req).

  Record ModelState (T : t) : Type :=
    mkState
      {
        m_actors : Actors;
        m_state  : T.(h_state);
        m_trace  : Trace;
      }.

  (* Local Definition init_actors : Actors. *)
  (*   refine (fix go i := *)
  (*             match i with *)
  (*             | 0 => Vec.nil *)
  (*             | Fin.S i' => Vec.cons (start_actor i) (go i') *)
  (*             end). *)



  (* Inductive model_step (s : ModelState) : ModelState -> Prop := *)
  (* | mod_init : forall s0, H.(h_initial_state) s0 -> *)
  (*                   mkState init_actors s0 []. *)

  Definition exit {T : t} : @Actor T := a_dead.
End IOHandler.

Module Mutable.
  Import IOHandler.

  Inductive req_t {T : Set} :=
  | get : req_t
  | put : T -> req_t.

  Local Definition ret_t {T : Set}  (req : @req_t T) : Set :=
    match req with
    | get => T
    | _   => True
    end.

  Local Definition eval_f {T : Set} (s0 : T) (aid : AID) (req : req_t) : @HandlerRet req_t T req ret_t :=
    match req with
    | get   => r_return _ s0 s0
    | put x => r_return _ I x
    end.

  Inductive example_initial_state {T : Set} : T -> Prop :=
  | example_initial_state1 : forall (x : T), example_initial_state x.

  Definition t T :=
    {|
      h_state := T;
      h_req := req_t;
      h_initial_state := example_initial_state;
      h_eval := fun s0 aid req ret => ret = eval_f s0 aid req;
    |}.
End Mutable.

Module Mutex.
  Import IOHandler.

  Inductive req_t :=
  | grab    : req_t
  | release : req_t.

  Local Definition ret_t (_ : req_t) : Set := True.

  Local Definition state_t := option AID.

  Local Definition eval_f (s0 : state_t) (aid : AID) (req : req_t) : @HandlerRet req_t state_t req ret_t :=
    match req, s0 with
    | grab, None   => r_return _ I (Some aid)
    | grab, Some _ => r_stall _
    | release, _   => r_return _ I None
    end.

  Definition t :=
    {|
      h_state := state_t;
      h_req := req_t;
      h_initial_state := fun s0 => s0 = None;
      h_eval := fun s0 aid req ret => ret = eval_f s0 aid req;
    |}.
End Mutex.

Module ExampleModelDefn.
  Import IOHandler.
  Local Definition handler := compose (Mutable.t nat) Mutex.t.

  Notation "'sync' V '<-' I ; C" := (@a_sync1 handler (I) (fun V => C))
                                    (at level 100, C at next level, V ident, right associativity).

  Local Definition put (val : nat) : h_req handler :=
    inl (Mutable.put val).

  Local Definition get : h_req handler :=
    inl (Mutable.get).

  Local Definition grab : h_req handler :=
    inr (Mutex.grab).

  Local Definition release : h_req handler :=
    inr (Mutex.release).

  (* Just a demonstration that we can define programs that loop
  indefinitely, as long as they do IO: *)
  Local CoFixpoint infinite_loop (aid : AID) : @Actor handler :=
    @a_sync1 handler (put 1) (fun ret => infinite_loop aid).

  (* Data race example: *)
  Local Definition counter_race (_ : AID) : @Actor handler :=
    sync v <- get;
    sync _ <- put (v + 1);
    exit.

  (* Fixed example: *)
  Local Definition counter_correct (_ : AID) : @Actor handler :=
    sync _ <- grab;
    sync v <- get;
    sync _ <- put (v + 1);
    sync _ <- release;
    exit.
End ExampleModelDefn.
