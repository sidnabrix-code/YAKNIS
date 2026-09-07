-- ============================================================
-- OMS - SCRIPT COMPLET (tout en un)
-- À coller EN UNE SEULE FOIS dans Supabase → SQL Editor → Run
-- Contient : schéma + fonctions métier + accès ouvert + captures d'écran
-- ============================================================

-- ============================================================
-- OMS - Nettoyage + Reconstruction complète du schéma
-- ============================================================

drop table if exists public.billing cascade;
drop table if exists public.order_history cascade;
drop table if exists public.orders cascade;
drop table if exists public.users cascade;
drop type if exists user_role cascade;
drop type if exists order_source cascade;
drop type if exists order_stage cascade;
drop type if exists order_status cascade;
drop type if exists payment_status cascade;
drop sequence if exists order_number_seq;
drop function if exists generate_order_number cascade;
drop function if exists set_updated_at cascade;
drop function if exists block_history_mutation cascade;
drop function if exists my_role cascade;

-- ============================================================
-- OMS - Order Management System
-- Fichier 1/2 : Schéma de base (tables, contraintes, index, RLS)
-- À coller dans Supabase → SQL Editor → Run
-- ============================================================

-- Extension pour UUID
create extension if not exists "pgcrypto";

-- ============================================================
-- ENUMS
-- ============================================================

create type user_role as enum (
  'ADMIN',
  'TEAM_MESSAGES',
  'TEAM_CONFIRMATION',
  'TEAM_DELIVERY',
  'TEAM_BILLING'
);

create type order_source as enum (
  'WHATSAPP',
  'FACEBOOK',
  'INSTAGRAM'
);

create type order_stage as enum (
  'CONFIRMATION',
  'DELIVERY',
  'BILLING',
  'CLOSED'
);

create type order_status as enum (
  -- Confirmation
  'NEW',
  'CONFIRMED',
  'NO_RESPONSE',
  'VOICEMAIL',
  'FALSE_NUMBER',
  'CANCELLED',
  -- Delivery
  'RAMASSEE',
  'EN_LIVRAISON',
  'PAS_DE_REPONSE',
  'PREMIER_APPEL',
  'DEUXIEME_APPEL',
  'TROISIEME_APPEL',
  'CLIENT_INTERESSE',
  'REPORTEE',
  'ANNULEE',
  'LIVREE',
  'REFUSEE'
);

create type payment_status as enum (
  'PAID',
  'UNPAID'
);

-- ============================================================
-- TABLE: users (liée à auth.users de Supabase)
-- ============================================================

create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (trim(name) <> ''),
  email text not null unique,
  role user_role not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_users_role on public.users(role);

-- ============================================================
-- TABLE: orders
-- ============================================================

create sequence if not exists order_number_seq start 1;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  source order_source not null,
  customer_name text not null check (trim(customer_name) <> ''),
  customer_city text not null check (trim(customer_city) <> ''),
  customer_address text not null check (trim(customer_address) <> ''),
  customer_phone text not null check (trim(customer_phone) <> ''),
  product_name text not null check (trim(product_name) <> ''),
  product_price numeric(10,2) not null check (product_price > 0),
  current_stage order_stage not null default 'CONFIRMATION',
  current_status order_status not null default 'NEW',
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_orders_stage on public.orders(current_stage);
create index idx_orders_status on public.orders(current_status);
create index idx_orders_source on public.orders(source);
create index idx_orders_created_at on public.orders(created_at);
create index idx_orders_created_by on public.orders(created_by);
create index idx_orders_order_number on public.orders(order_number);
create index idx_orders_customer_phone on public.orders(customer_phone);

-- Génération automatique du numéro de commande : CMD-000001
create or replace function generate_order_number()
returns trigger as $$
begin
  if new.order_number is null then
    new.order_number := 'CMD-' || lpad(nextval('order_number_seq')::text, 6, '0');
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_generate_order_number
before insert on public.orders
for each row execute function generate_order_number();

-- Mise à jour automatique de updated_at
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_orders_updated_at
before update on public.orders
for each row execute function set_updated_at();

-- ============================================================
-- TABLE: order_history (append-only, immuable)
-- ============================================================

create table public.order_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  old_stage order_stage,
  new_stage order_stage,
  old_status order_status,
  new_status order_status,
  comment text,
  changed_by uuid references public.users(id),
  created_at timestamptz not null default now()
);

create index idx_history_order_id on public.order_history(order_id);
create index idx_history_created_at on public.order_history(created_at);
create index idx_history_changed_by on public.order_history(changed_by);

-- Empêcher toute modification ou suppression de l'historique
create or replace function block_history_mutation()
returns trigger as $$
begin
  raise exception 'order_history est en lecture seule (append-only)';
end;
$$ language plpgsql;

create trigger trg_block_history_update
before update on public.order_history
for each row execute function block_history_mutation();

create trigger trg_block_history_delete
before delete on public.order_history
for each row execute function block_history_mutation();

-- ============================================================
-- TABLE: billing
-- ============================================================

create table public.billing (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id),
  delivery_price numeric(10,2) not null check (delivery_price >= 0),
  net_profit numeric(10,2),
  payment_status payment_status not null default 'UNPAID',
  created_by uuid references public.users(id),
  updated_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_billing_updated_at
before update on public.billing
for each row execute function set_updated_at();

-- ============================================================
-- RLS : activation
-- ============================================================

alter table public.users enable row level security;
alter table public.orders enable row level security;
alter table public.order_history enable row level security;
alter table public.billing enable row level security;

-- Fonction utilitaire : rôle de l'utilisateur connecté
create or replace function my_role()
returns user_role as $$
  select role from public.users where id = auth.uid();
$$ language sql stable security definer;

-- --- users ---
create policy "users_select_own_or_admin" on public.users
for select using (
  id = auth.uid() or my_role() = 'ADMIN'
);

-- --- orders : lecture selon le rôle ---
create policy "orders_select_by_role" on public.orders
for select using (
  my_role() = 'ADMIN'
  or (my_role() = 'TEAM_MESSAGES' and created_by = auth.uid())
  or (my_role() = 'TEAM_CONFIRMATION' and current_stage = 'CONFIRMATION')
  or (my_role() = 'TEAM_DELIVERY' and current_stage = 'DELIVERY')
  or (my_role() = 'TEAM_BILLING' and current_stage = 'BILLING')
);

-- Écriture directe désactivée : toutes les modifications passent
-- par des fonctions RPC (SECURITY DEFINER) définies dans le fichier 2.
create policy "orders_insert_messages" on public.orders
for insert with check (my_role() in ('TEAM_MESSAGES','ADMIN'));

-- --- order_history : lecture seule pour tous les rôles concernés ---
create policy "history_select_by_role" on public.order_history
for select using (
  my_role() = 'ADMIN'
  or exists (
    select 1 from public.orders o
    where o.id = order_id
  )
);

-- --- billing : lecture réservée à Billing + Admin ---
create policy "billing_select_by_role" on public.billing
for select using (
  my_role() in ('ADMIN','TEAM_BILLING')
);

-- Fin du fichier 1/2. Passez au fichier 2 (fonctions métier / RPC).

-- ============================================================
-- OMS - Fichier 2/2 : Fonctions métier (RPC) + Workflow
-- À coller dans Supabase → SQL Editor → Run
-- (à exécuter APRÈS 01_schema_clean.sql)
-- ============================================================

-- On retire la possibilité d'insérer une commande directement
-- depuis le client : toute création DOIT passer par create_order()
-- pour garantir que l'historique est bien créé en même temps.
drop policy if exists "orders_insert_messages" on public.orders;

-- ============================================================
-- Fonction utilitaire : vérifier le rôle, sinon erreur claire
-- ============================================================

create or replace function check_role(allowed_roles user_role[])
returns void as $$
begin
  if my_role() is null then
    raise exception 'Utilisateur non reconnu ou inactif';
  end if;
  if not (my_role() = any(allowed_roles)) then
    raise exception 'Action non autorisée pour le rôle %', my_role();
  end if;
end;
$$ language plpgsql security definer;

-- ============================================================
-- 1) create_order : TEAM_MESSAGES / ADMIN
-- ============================================================

create or replace function create_order(
  p_source order_source,
  p_customer_name text,
  p_customer_city text,
  p_customer_address text,
  p_customer_phone text,
  p_product_name text,
  p_product_price numeric
)
returns public.orders as $$
declare
  v_order public.orders;
begin
  perform check_role(array['TEAM_MESSAGES','ADMIN']::user_role[]);

  if trim(p_customer_name) = '' or trim(p_customer_city) = ''
     or trim(p_customer_address) = '' or trim(p_customer_phone) = ''
     or trim(p_product_name) = '' then
    raise exception 'Tous les champs sont obligatoires';
  end if;

  if p_product_price is null or p_product_price <= 0 then
    raise exception 'Le prix du produit doit être un nombre positif';
  end if;

  insert into public.orders (
    source, customer_name, customer_city, customer_address,
    customer_phone, product_name, product_price,
    current_stage, current_status, created_by
  ) values (
    p_source, trim(p_customer_name), trim(p_customer_city), trim(p_customer_address),
    trim(p_customer_phone), trim(p_product_name), p_product_price,
    'CONFIRMATION', 'NEW', auth.uid()
  ) returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment, changed_by
  ) values (
    v_order.id, null, 'CONFIRMATION', null, 'NEW',
    'Commande créée', auth.uid()
  );

  return v_order;
end;
$$ language plpgsql security definer;

-- ============================================================
-- 2) confirm_order : CONFIRMATION -> DELIVERY (statut CONFIRMED)
--    TEAM_CONFIRMATION / ADMIN
-- ============================================================

create or replace function confirm_order(p_order_id uuid)
returns public.orders as $$
declare
  v_order public.orders;
begin
  perform check_role(array['TEAM_CONFIRMATION','ADMIN']::user_role[]);

  select * into v_order from public.orders where id = p_order_id for update;

  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'CONFIRMATION' then
    raise exception 'Transition invalide : la commande n''est pas au stade Confirmation';
  end if;

  update public.orders
  set current_status = 'CONFIRMED', current_stage = 'DELIVERY'
  where id = p_order_id
  returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment, changed_by
  ) values (
    p_order_id, 'CONFIRMATION', 'DELIVERY', 'NEW', 'CONFIRMED',
    'Commande confirmée', auth.uid()
  );

  return v_order;
end;
$$ language plpgsql security definer;

-- ============================================================
-- 3) set_confirmation_status : NO_RESPONSE / VOICEMAIL /
--    FALSE_NUMBER / CANCELLED — TEAM_CONFIRMATION / ADMIN
-- ============================================================

create or replace function set_confirmation_status(
  p_order_id uuid,
  p_new_status order_status,
  p_comment text default null
)
returns public.orders as $$
declare
  v_order public.orders;
  v_new_stage order_stage;
begin
  perform check_role(array['TEAM_CONFIRMATION','ADMIN']::user_role[]);

  if p_new_status not in ('NO_RESPONSE','VOICEMAIL','FALSE_NUMBER','CANCELLED') then
    raise exception 'Statut invalide pour cette action';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'CONFIRMATION' then
    raise exception 'Transition invalide : la commande n''est pas au stade Confirmation';
  end if;

  if p_new_status in ('FALSE_NUMBER','CANCELLED') then
    v_new_stage := 'CLOSED';
  else
    v_new_stage := 'CONFIRMATION';
  end if;

  update public.orders
  set current_status = p_new_status, current_stage = v_new_stage
  where id = p_order_id
  returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment, changed_by
  ) values (
    p_order_id, 'CONFIRMATION', v_new_stage, v_order.current_status, p_new_status,
    p_comment, auth.uid()
  );

  return v_order;
end;
$$ language plpgsql security definer;

-- ============================================================
-- 4) update_delivery_status : TEAM_DELIVERY / ADMIN
--    Gère tous les statuts de livraison, y compris LIVREE et
--    REFUSEE qui déclenchent automatiquement la facturation.
-- ============================================================

create or replace function update_delivery_status(
  p_order_id uuid,
  p_new_status order_status,
  p_comment text default null
)
returns public.orders as $$
declare
  v_order public.orders;
  v_new_stage order_stage;
  v_old_stage order_stage;
  v_old_status order_status;
begin
  perform check_role(array['TEAM_DELIVERY','ADMIN']::user_role[]);

  if p_new_status not in (
    'RAMASSEE','EN_LIVRAISON','PAS_DE_REPONSE','PREMIER_APPEL',
    'DEUXIEME_APPEL','TROISIEME_APPEL','CLIENT_INTERESSE',
    'REPORTEE','ANNULEE','LIVREE','REFUSEE'
  ) then
    raise exception 'Statut de livraison invalide';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'DELIVERY' then
    raise exception 'Transition invalide : la commande n''est pas au stade Livraison';
  end if;

  -- Commentaire obligatoire et significatif pour ces statuts
  if p_new_status in ('REPORTEE','ANNULEE','REFUSEE') then
    if p_comment is null or length(trim(p_comment)) < 3 then
      raise exception 'Un commentaire est obligatoire pour le statut %', p_new_status;
    end if;
  end if;

  v_old_stage := v_order.current_stage;
  v_old_status := v_order.current_status;

  -- Détermination du nouveau stage
  if p_new_status = 'LIVREE' then
    v_new_stage := 'BILLING';
  elsif p_new_status = 'REFUSEE' then
    v_new_stage := 'BILLING';
  elsif p_new_status = 'ANNULEE' then
    -- Annulée à ce stade est définitivement fermée
    -- (ne doit pas se retrouver en Facturation par erreur)
    v_new_stage := 'CLOSED';
  else
    v_new_stage := 'DELIVERY';
  end if;

  update public.orders
  set current_status = p_new_status, current_stage = v_new_stage
  where id = p_order_id
  returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment, changed_by
  ) values (
    p_order_id, v_old_stage, v_new_stage, v_old_status, p_new_status,
    p_comment, auth.uid()
  );

  -- REFUSEE : création automatique de la facturation avec 10 DH verrouillé
  if p_new_status = 'REFUSEE' then
    insert into public.billing (order_id, delivery_price, payment_status, created_by)
    values (p_order_id, 10, 'UNPAID', auth.uid());

    insert into public.order_history (
      order_id, old_stage, new_stage, old_status, new_status, comment, changed_by
    ) values (
      p_order_id, 'BILLING', 'BILLING', p_new_status, p_new_status,
      'Prix de livraison fixé automatiquement à 10 DH', auth.uid()
    );
  end if;

  return v_order;
end;
$$ language plpgsql security definer;

-- ============================================================
-- 5) update_billing : TEAM_BILLING / ADMIN
--    LIVREE  -> saisie libre (delivery_price + net_profit)
--    REFUSEE -> delivery_price verrouillé à 10 DH (déjà créé)
-- ============================================================

create or replace function update_billing(
  p_order_id uuid,
  p_delivery_price numeric default null,
  p_net_profit numeric default null,
  p_payment_status payment_status default null
)
returns public.billing as $$
declare
  v_order public.orders;
  v_billing public.billing;
begin
  perform check_role(array['TEAM_BILLING','ADMIN']::user_role[]);

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'BILLING' then
    raise exception 'Transition invalide : la commande n''est pas au stade Facturation';
  end if;

  select * into v_billing from public.billing where order_id = p_order_id for update;

  if v_order.current_status = 'REFUSEE' then
    -- Le prix de livraison est verrouillé, toute valeur envoyée est ignorée
    update public.billing
    set net_profit = coalesce(p_net_profit, net_profit),
        payment_status = coalesce(p_payment_status, payment_status),
        updated_by = auth.uid()
    where order_id = p_order_id
    returning * into v_billing;

  elsif v_order.current_status = 'LIVREE' then
    if v_billing is null then
      if p_delivery_price is null or p_delivery_price < 0 then
        raise exception 'Le prix de livraison doit être un nombre positif ou nul';
      end if;
      insert into public.billing (
        order_id, delivery_price, net_profit, payment_status, created_by
      ) values (
        p_order_id, p_delivery_price, p_net_profit,
        coalesce(p_payment_status, 'UNPAID'), auth.uid()
      ) returning * into v_billing;
    else
      update public.billing
      set delivery_price = coalesce(p_delivery_price, delivery_price),
          net_profit = coalesce(p_net_profit, net_profit),
          payment_status = coalesce(p_payment_status, payment_status),
          updated_by = auth.uid()
      where order_id = p_order_id
      returning * into v_billing;
    end if;
  else
    raise exception 'Statut de commande incompatible avec la facturation';
  end if;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment, changed_by
  ) values (
    p_order_id, 'BILLING', 'BILLING', v_order.current_status, v_order.current_status,
    format('Facturation mise à jour (statut paiement: %s)', v_billing.payment_status),
    auth.uid()
  );

  return v_billing;
end;
$$ language plpgsql security definer;

-- Fin du fichier 2/2. Le workflow métier est maintenant complet.

-- ============================================================
-- OMS - Fichier 3/3 : Accès ouvert, SANS authentification
-- À coller dans Supabase → SQL Editor → Run
-- (à exécuter APRÈS 01_schema_clean.sql et 02_functions.sql)
-- ============================================================

-- 1) Désactiver complètement la sécurité par ligne (RLS)
--    Tout le monde ayant la clé du projet peut lire/écrire.
alter table public.users disable row level security;
alter table public.orders disable row level security;
alter table public.order_history disable row level security;
alter table public.billing disable row level security;

-- 2) Remplacer les fonctions métier pour ne plus exiger
--    de rôle ni d'utilisateur connecté (changed_by reste vide).

create or replace function create_order(
  p_source order_source,
  p_customer_name text,
  p_customer_city text,
  p_customer_address text,
  p_customer_phone text,
  p_product_name text,
  p_product_price numeric
)
returns public.orders as $$
declare
  v_order public.orders;
begin
  if trim(p_customer_name) = '' or trim(p_customer_city) = ''
     or trim(p_customer_address) = '' or trim(p_customer_phone) = ''
     or trim(p_product_name) = '' then
    raise exception 'Tous les champs sont obligatoires';
  end if;

  if p_product_price is null or p_product_price <= 0 then
    raise exception 'Le prix du produit doit être un nombre positif';
  end if;

  insert into public.orders (
    source, customer_name, customer_city, customer_address,
    customer_phone, product_name, product_price,
    current_stage, current_status
  ) values (
    p_source, trim(p_customer_name), trim(p_customer_city), trim(p_customer_address),
    trim(p_customer_phone), trim(p_product_name), p_product_price,
    'CONFIRMATION', 'NEW'
  ) returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment
  ) values (
    v_order.id, null, 'CONFIRMATION', null, 'NEW', 'Commande créée'
  );

  return v_order;
end;
$$ language plpgsql security definer;

create or replace function confirm_order(p_order_id uuid)
returns public.orders as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'CONFIRMATION' then
    raise exception 'Transition invalide : la commande n''est pas au stade Confirmation';
  end if;

  update public.orders
  set current_status = 'CONFIRMED', current_stage = 'DELIVERY'
  where id = p_order_id
  returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment
  ) values (
    p_order_id, 'CONFIRMATION', 'DELIVERY', 'NEW', 'CONFIRMED', 'Commande confirmée'
  );

  return v_order;
end;
$$ language plpgsql security definer;

create or replace function set_confirmation_status(
  p_order_id uuid,
  p_new_status order_status,
  p_comment text default null
)
returns public.orders as $$
declare
  v_order public.orders;
  v_new_stage order_stage;
begin
  if p_new_status not in ('NO_RESPONSE','VOICEMAIL','FALSE_NUMBER','CANCELLED') then
    raise exception 'Statut invalide pour cette action';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'CONFIRMATION' then
    raise exception 'Transition invalide : la commande n''est pas au stade Confirmation';
  end if;

  if p_new_status in ('FALSE_NUMBER','CANCELLED') then
    v_new_stage := 'CLOSED';
  else
    v_new_stage := 'CONFIRMATION';
  end if;

  update public.orders
  set current_status = p_new_status, current_stage = v_new_stage
  where id = p_order_id
  returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment
  ) values (
    p_order_id, 'CONFIRMATION', v_new_stage, v_order.current_status, p_new_status, p_comment
  );

  return v_order;
end;
$$ language plpgsql security definer;

create or replace function update_delivery_status(
  p_order_id uuid,
  p_new_status order_status,
  p_comment text default null
)
returns public.orders as $$
declare
  v_order public.orders;
  v_new_stage order_stage;
  v_old_stage order_stage;
  v_old_status order_status;
begin
  if p_new_status not in (
    'RAMASSEE','EN_LIVRAISON','PAS_DE_REPONSE','PREMIER_APPEL',
    'DEUXIEME_APPEL','TROISIEME_APPEL','CLIENT_INTERESSE',
    'REPORTEE','ANNULEE','LIVREE','REFUSEE'
  ) then
    raise exception 'Statut de livraison invalide';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'DELIVERY' then
    raise exception 'Transition invalide : la commande n''est pas au stade Livraison';
  end if;

  if p_new_status in ('REPORTEE','ANNULEE','REFUSEE') then
    if p_comment is null or length(trim(p_comment)) < 3 then
      raise exception 'Un commentaire est obligatoire pour le statut %', p_new_status;
    end if;
  end if;

  v_old_stage := v_order.current_stage;
  v_old_status := v_order.current_status;

  if p_new_status = 'LIVREE' then
    v_new_stage := 'BILLING';
  elsif p_new_status = 'REFUSEE' then
    v_new_stage := 'BILLING';
  elsif p_new_status = 'ANNULEE' then
    v_new_stage := 'CLOSED';
  else
    v_new_stage := 'DELIVERY';
  end if;

  update public.orders
  set current_status = p_new_status, current_stage = v_new_stage
  where id = p_order_id
  returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment
  ) values (
    p_order_id, v_old_stage, v_new_stage, v_old_status, p_new_status, p_comment
  );

  if p_new_status = 'REFUSEE' then
    insert into public.billing (order_id, delivery_price, payment_status)
    values (p_order_id, 10, 'UNPAID');

    insert into public.order_history (
      order_id, old_stage, new_stage, old_status, new_status, comment
    ) values (
      p_order_id, 'BILLING', 'BILLING', p_new_status, p_new_status,
      'Prix de livraison fixé automatiquement à 10 DH'
    );
  end if;

  return v_order;
end;
$$ language plpgsql security definer;

create or replace function update_billing(
  p_order_id uuid,
  p_delivery_price numeric default null,
  p_net_profit numeric default null,
  p_payment_status payment_status default null
)
returns public.billing as $$
declare
  v_order public.orders;
  v_billing public.billing;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'Commande introuvable';
  end if;
  if v_order.current_stage <> 'BILLING' then
    raise exception 'Transition invalide : la commande n''est pas au stade Facturation';
  end if;

  select * into v_billing from public.billing where order_id = p_order_id for update;

  if v_order.current_status = 'REFUSEE' then
    update public.billing
    set net_profit = coalesce(p_net_profit, net_profit),
        payment_status = coalesce(p_payment_status, payment_status)
    where order_id = p_order_id
    returning * into v_billing;

  elsif v_order.current_status = 'LIVREE' then
    if v_billing is null then
      if p_delivery_price is null or p_delivery_price < 0 then
        raise exception 'Le prix de livraison doit être un nombre positif ou nul';
      end if;
      insert into public.billing (
        order_id, delivery_price, net_profit, payment_status
      ) values (
        p_order_id, p_delivery_price, p_net_profit, coalesce(p_payment_status, 'UNPAID')
      ) returning * into v_billing;
    else
      update public.billing
      set delivery_price = coalesce(p_delivery_price, delivery_price),
          net_profit = coalesce(p_net_profit, net_profit),
          payment_status = coalesce(p_payment_status, payment_status)
      where order_id = p_order_id
      returning * into v_billing;
    end if;
  else
    raise exception 'Statut de commande incompatible avec la facturation';
  end if;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment
  ) values (
    p_order_id, 'BILLING', 'BILLING', v_order.current_status, v_order.current_status,
    format('Facturation mise à jour (statut paiement: %s)', v_billing.payment_status)
  );

  return v_billing;
end;
$$ language plpgsql security definer;

-- Fin du fichier 3/3. Le système est maintenant ouvert, sans connexion requise.

-- ============================================================
-- OMS - Fichier 4/4 : Capture d'écran de la conversation client
-- À coller dans Supabase → SQL Editor → Run
-- (à exécuter APRÈS 03_open_access.sql)
-- ============================================================

-- 1) Nouvelle colonne sur orders pour stocker le lien de l'image
alter table public.orders
  add column if not exists conversation_screenshot_url text;

-- 2) Créer le bucket de stockage public pour les captures d'écran
insert into storage.buckets (id, name, public)
values ('conversation-screenshots', 'conversation-screenshots', true)
on conflict (id) do nothing;

-- 3) Autoriser l'upload et la lecture publique sur ce bucket
--    (cohérent avec le choix d'un système ouvert, sans connexion)
drop policy if exists "screenshots_public_read" on storage.objects;
create policy "screenshots_public_read" on storage.objects
for select using (bucket_id = 'conversation-screenshots');

drop policy if exists "screenshots_public_upload" on storage.objects;
create policy "screenshots_public_upload" on storage.objects
for insert with check (bucket_id = 'conversation-screenshots');

-- 4) Mettre à jour create_order() pour accepter le lien de la capture
create or replace function create_order(
  p_source order_source,
  p_customer_name text,
  p_customer_city text,
  p_customer_address text,
  p_customer_phone text,
  p_product_name text,
  p_product_price numeric,
  p_screenshot_url text default null
)
returns public.orders as $$
declare
  v_order public.orders;
begin
  if trim(p_customer_name) = '' or trim(p_customer_city) = ''
     or trim(p_customer_address) = '' or trim(p_customer_phone) = ''
     or trim(p_product_name) = '' then
    raise exception 'Tous les champs sont obligatoires';
  end if;

  if p_product_price is null or p_product_price <= 0 then
    raise exception 'Le prix du produit doit être un nombre positif';
  end if;

  insert into public.orders (
    source, customer_name, customer_city, customer_address,
    customer_phone, product_name, product_price,
    current_stage, current_status, conversation_screenshot_url
  ) values (
    p_source, trim(p_customer_name), trim(p_customer_city), trim(p_customer_address),
    trim(p_customer_phone), trim(p_product_name), p_product_price,
    'CONFIRMATION', 'NEW', p_screenshot_url
  ) returning * into v_order;

  insert into public.order_history (
    order_id, old_stage, new_stage, old_status, new_status, comment
  ) values (
    v_order.id, null, 'CONFIRMATION', null, 'NEW', 'Commande créée'
  );

  return v_order;
end;
$$ language plpgsql security definer;

-- Fin du fichier 4/4.
