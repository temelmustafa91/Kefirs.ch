-- Comptoir: carte, stocks, recettes, commandes, planning.

create table shop (
  id integer primary key check (id = 1),
  name text not null,
  tagline text not null,
  announcement text not null default '',
  address text not null default '',
  pin_code text not null check (pin_code ~ '^[0-9]{4}$'),
  open_time text not null,
  close_time text not null,
  evening_open text,
  evening_close text,
  slot_minutes integer not null default 30 check (slot_minutes in (15, 30, 60)),
  slot_capacity integer not null default 10 check (slot_capacity > 0),
  closed_dows text not null default '0,1'
);

create table stock_items (
  id serial primary key,
  name text not null,
  unit text not null check (unit in ('g', 'ml', 'pièce')),
  quantity integer not null check (quantity >= 0),
  threshold integer not null default 0 check (threshold >= 0)
);

create table recipes (
  id serial primary key,
  name text not null,
  description text not null default '',
  category text not null,
  price_cents integer not null check (price_cents > 0),
  prep_minutes integer not null default 15 check (prep_minutes >= 0),
  published boolean not null default true,
  image text not null default '',
  sort_order integer not null default 0
);

create table recipe_lines (
  id serial primary key,
  recipe_id integer not null references recipes (id) on delete cascade,
  stock_item_id integer not null references stock_items (id),
  quantity integer not null check (quantity > 0)
);

create table orders (
  id serial primary key,
  code text not null unique,
  slot_date date not null,
  slot_time text not null,
  status text not null default 'recue' check (status in ('recue', 'preparation', 'prete', 'retiree', 'annulee')),
  notes text not null default '',
  total_cents integer not null check (total_cents >= 0),
  created_at timestamptz not null default now()
);

create table order_lines (
  id serial primary key,
  order_id integer not null references orders (id) on delete cascade,
  recipe_id integer references recipes (id) on delete set null,
  name text not null,
  qty integer not null check (qty > 0),
  unit_cents integer not null check (unit_cents >= 0)
);

create table order_stock (
  id serial primary key,
  order_id integer not null references orders (id) on delete cascade,
  stock_item_id integer not null references stock_items (id),
  quantity integer not null check (quantity > 0)
);

create table stock_moves (
  id serial primary key,
  stock_item_id integer not null references stock_items (id) on delete cascade,
  delta integer not null,
  reason text not null,
  created_at timestamptz not null default now()
);

create table closures (
  day date primary key,
  reason text not null default ''
);

create index orders_slot_idx on orders (slot_date, slot_time);
create index order_lines_order_idx on order_lines (order_id);
create index recipe_lines_recipe_idx on recipe_lines (recipe_id);

create or replace function place_comptoir_order(
  payload jsonb,
  order_code text,
  p_date date,
  p_time text,
  order_notes text
) returns table (
  order_id integer,
  total_cents integer,
  placed_code text,
  recipes_ok boolean,
  published_ok boolean,
  stock_ok boolean,
  capacity_ok boolean,
  open_ok boolean,
  short_names text
)
language plpgsql
as $$
declare
  v_lines integer;
  v_found integer;
  v_recipes_ok boolean := false;
  v_published_ok boolean := false;
  v_stock_ok boolean := true;
  v_capacity_ok boolean := false;
  v_open_ok boolean := false;
  v_short text := null;
  v_total integer := 0;
  v_id integer := null;
  v_cap integer := 0;
  v_used integer := 0;
  v_add integer := 0;
  rec record;
begin
  perform 1 from shop where id = 1 for update;

  perform id
  from stock_items
  where id in (
    select rl.stock_item_id
    from jsonb_array_elements(payload) as line
    join recipe_lines rl on rl.recipe_id = (line->>'recipeId')::integer
  )
  order by id
  for update;

  select count(*)::integer into v_lines from jsonb_array_elements(payload) as line;

  select count(*)::integer into v_found
  from jsonb_array_elements(payload) as line
  join recipes r on r.id = (line->>'recipeId')::integer;

  v_recipes_ok := v_lines > 0 and v_lines = v_found;

  select coalesce(bool_and(r.published), false) into v_published_ok
  from jsonb_array_elements(payload) as line
  join recipes r on r.id = (line->>'recipeId')::integer;

  for rec in
    select s.name as item_name,
           s.quantity as have,
           sum(rl.quantity * (line->>'qty')::integer)::integer as need
    from jsonb_array_elements(payload) as line
    join recipe_lines rl on rl.recipe_id = (line->>'recipeId')::integer
    join stock_items s on s.id = rl.stock_item_id
    group by s.id, s.name, s.quantity
  loop
    if rec.have < rec.need then
      v_stock_ok := false;
      v_short := concat_ws(', ', v_short, rec.item_name);
    end if;
  end loop;

  select slot_capacity into v_cap from shop where id = 1;

  select coalesce(sum(l.qty), 0)::integer into v_used
  from orders o
  join order_lines l on l.order_id = o.id
  where o.slot_date = p_date
    and o.slot_time = p_time
    and o.status <> 'annulee';

  select coalesce(sum((line->>'qty')::integer), 0)::integer into v_add
  from jsonb_array_elements(payload) as line;

  v_capacity_ok := v_used + v_add <= v_cap;

  select not exists (select 1 from closures c where c.day = p_date) into v_open_ok;

  if v_recipes_ok and v_published_ok and v_stock_ok and v_capacity_ok and v_open_ok then
    select coalesce(sum(r.price_cents * (line->>'qty')::integer), 0)::integer into v_total
    from jsonb_array_elements(payload) as line
    join recipes r on r.id = (line->>'recipeId')::integer;

    insert into orders (code, slot_date, slot_time, status, notes, total_cents)
    values (order_code, p_date, p_time, 'recue', order_notes, v_total)
    returning id into v_id;

    insert into order_lines (order_id, recipe_id, name, qty, unit_cents)
    select v_id, r.id, r.name, (line->>'qty')::integer, r.price_cents
    from jsonb_array_elements(payload) as line
    join recipes r on r.id = (line->>'recipeId')::integer;

    insert into order_stock (order_id, stock_item_id, quantity)
    select v_id, rl.stock_item_id, sum(rl.quantity * (line->>'qty')::integer)::integer
    from jsonb_array_elements(payload) as line
    join recipe_lines rl on rl.recipe_id = (line->>'recipeId')::integer
    group by rl.stock_item_id;

    insert into stock_moves (stock_item_id, delta, reason)
    select rl.stock_item_id,
           -sum(rl.quantity * (line->>'qty')::integer)::integer,
           'Commande ' || order_code
    from jsonb_array_elements(payload) as line
    join recipe_lines rl on rl.recipe_id = (line->>'recipeId')::integer
    group by rl.stock_item_id;

    update stock_items s
    set quantity = s.quantity - n.need
    from (
      select rl.stock_item_id, sum(rl.quantity * (line->>'qty')::integer)::integer as need
      from jsonb_array_elements(payload) as line
      join recipe_lines rl on rl.recipe_id = (line->>'recipeId')::integer
      group by rl.stock_item_id
    ) as n
    where s.id = n.stock_item_id;
  end if;

  return query
  select v_id, v_total, order_code, v_recipes_ok, v_published_ok, v_stock_ok, v_capacity_ok, v_open_ok, v_short;
end;
$$;

create or replace function cancel_comptoir_order(p_id integer)
returns table (previous text, updated integer)
language plpgsql
as $$
declare
  v_status text;
  v_code text;
  v_updated integer := 0;
begin
  select status, code into v_status, v_code from orders where id = p_id for update;
  if v_status is null then
    return query select null::text, 0;
    return;
  end if;

  if v_status in ('recue', 'preparation', 'prete') then
    update orders set status = 'annulee' where id = p_id;
    get diagnostics v_updated = row_count;

    update stock_items s
    set quantity = s.quantity + b.qty
    from (
      select stock_item_id, sum(quantity)::integer as qty
      from order_stock
      where order_id = p_id
      group by stock_item_id
    ) as b
    where s.id = b.stock_item_id;

    insert into stock_moves (stock_item_id, delta, reason)
    select stock_item_id, sum(quantity)::integer, 'Annulation ' || v_code
    from order_stock
    where order_id = p_id
    group by stock_item_id;
  end if;

  return query select v_status, v_updated;
end;
$$;

insert into shop (
  id, name, tagline, announcement, address, pin_code,
  open_time, close_time, evening_open, evening_close,
  slot_minutes, slot_capacity, closed_dows
) values (
  1,
  'Maison Brume',
  'La cuisine du jour, à retirer au comptoir.',
  'Les tourtes et le poulet partent en début de service. Choisissez un créneau.',
  '12 rue des Ateliers',
  '4820',
  '11:30',
  '14:30',
  '18:00',
  '20:30',
  30,
  10,
  '0,1'
);

insert into stock_items (id, name, unit, quantity, threshold) values
  (1, 'Potimarron', 'g', 4200, 1500),
  (2, 'Poireaux', 'g', 2800, 800),
  (3, 'Crème', 'ml', 1400, 400),
  (4, 'Beurre', 'g', 280, 300),
  (5, 'Farine', 'g', 3500, 800),
  (6, 'Œufs', 'pièce', 24, 8),
  (7, 'Poulet', 'pièce', 5, 4),
  (8, 'Herbes', 'g', 60, 20),
  (9, 'Citron', 'pièce', 4, 6),
  (10, 'Sucre', 'g', 1600, 400),
  (11, 'Lentilles', 'g', 2200, 500),
  (12, 'Olives', 'g', 700, 200),
  (13, 'Romarin', 'g', 12, 20),
  (14, 'Yaourt', 'ml', 900, 250);

select setval('stock_items_id_seq', (select max(id) from stock_items));

insert into recipes (id, name, description, category, price_cents, prep_minutes, published, image, sort_order) values
  (1, 'Velouté de potimarron', 'Potimarron rôti, crème et graines toastées.', 'Soupe', 900, 10, true, 'potimarron', 2),
  (2, 'Tarte fine aux poireaux', 'Poireaux fondus, pâte brisée au beurre.', 'Tarte', 1400, 15, true, 'poireaux', 3),
  (3, 'Poulet rôti aux herbes', 'Cuisse laquée, jus court au romarin.', 'Plat', 1850, 20, true, 'poulet', 4),
  (4, 'Salade de lentilles', 'Lentilles vertes, herbes et huile d''olive.', 'Entrée', 1100, 10, true, 'lentilles', 1),
  (5, 'Tarte au citron', 'Crème citron et pâte sucrée.', 'Dessert', 800, 10, true, 'citron', 6),
  (6, 'Cake olives et romarin', 'Cake salé, olives noires et romarin.', 'Cake', 650, 5, true, 'cake', 5);

select setval('recipes_id_seq', (select max(id) from recipes));

insert into recipe_lines (recipe_id, stock_item_id, quantity) values
  (1, 1, 200), (1, 3, 50),
  (2, 2, 150), (2, 4, 30), (2, 5, 50), (2, 6, 1),
  (3, 7, 1), (3, 8, 8),
  (4, 11, 90), (4, 8, 4),
  (5, 9, 1), (5, 4, 40), (5, 5, 30), (5, 6, 1), (5, 10, 40),
  (6, 5, 60), (6, 6, 1), (6, 12, 25), (6, 13, 3), (6, 14, 40);

insert into stock_moves (stock_item_id, delta, reason)
select id, quantity, 'Inventaire d''ouverture' from stock_items;

with days as (
  select g.d::date as d, row_number() over (order by g.d) as n
  from generate_series(current_date, current_date + 21, interval '1 day') as g(d)
  where extract(dow from g.d)::int not in (0, 1)
),
past as (
  select g.d::date as d, row_number() over (order by g.d desc) as n
  from generate_series(current_date - 21, current_date - 1, interval '1 day') as g(d)
  where extract(dow from g.d)::int not in (0, 1)
),
seed as (
  select * from (values
    ('BR-1842', 1, 0, '12:00', 'preparation', 'Bien chaud', 3200),
    ('BR-1907', 1, 0, '12:30', 'recue', 'Sauces à part', 3450),
    ('BR-2031', 1, 0, '18:30', 'prete', '', 1950),
    ('BR-2210', 2, 0, '12:00', 'recue', 'Sans couverts', 4050),
    ('BR-1044', 0, 1, '12:30', 'retiree', '', 1850),
    ('BR-1108', 0, 2, '13:00', 'retiree', '', 2300),
    ('BR-1215', 0, 3, '18:30', 'retiree', '', 1950),
    ('BR-1302', 0, 4, '12:00', 'retiree', '', 3750)
  ) as v(code, day_n, past_n, slot_time, status, notes, total_cents)
)
insert into orders (code, slot_date, slot_time, status, notes, total_cents)
select
  s.code,
  case
    when s.day_n > 0 then (select d from days where n = s.day_n)
    else (select d from past where n = s.past_n)
  end,
  s.slot_time,
  s.status,
  s.notes,
  s.total_cents
from seed as s;

insert into order_lines (order_id, recipe_id, name, qty, unit_cents)
select o.id, v.recipe_id, v.name, v.qty, v.unit_cents
from (values
  ('BR-1842', 1, 'Velouté de potimarron', 2, 900),
  ('BR-1842', 2, 'Tarte fine aux poireaux', 1, 1400),
  ('BR-1907', 3, 'Poulet rôti aux herbes', 1, 1850),
  ('BR-1907', 5, 'Tarte au citron', 2, 800),
  ('BR-2031', 6, 'Cake olives et romarin', 3, 650),
  ('BR-2210', 4, 'Salade de lentilles', 2, 1100),
  ('BR-2210', 3, 'Poulet rôti aux herbes', 1, 1850),
  ('BR-1044', 3, 'Poulet rôti aux herbes', 1, 1850),
  ('BR-1108', 1, 'Velouté de potimarron', 1, 900),
  ('BR-1108', 2, 'Tarte fine aux poireaux', 1, 1400),
  ('BR-1215', 6, 'Cake olives et romarin', 3, 650),
  ('BR-1302', 3, 'Poulet rôti aux herbes', 1, 1850),
  ('BR-1302', 4, 'Salade de lentilles', 1, 1100),
  ('BR-1302', 5, 'Tarte au citron', 1, 800)
) as v(code, recipe_id, name, qty, unit_cents)
join orders o on o.code = v.code;

insert into order_stock (order_id, stock_item_id, quantity)
select o.id, v.stock_item_id, v.quantity
from (values
  ('BR-1842', 1, 400),
  ('BR-1842', 3, 100),
  ('BR-1842', 2, 150),
  ('BR-1842', 4, 30),
  ('BR-1842', 5, 50),
  ('BR-1842', 6, 1),
  ('BR-1907', 7, 1),
  ('BR-1907', 8, 8),
  ('BR-1907', 9, 2),
  ('BR-1907', 4, 80),
  ('BR-1907', 5, 60),
  ('BR-1907', 6, 2),
  ('BR-1907', 10, 80),
  ('BR-2031', 5, 180),
  ('BR-2031', 6, 3),
  ('BR-2031', 12, 75),
  ('BR-2031', 13, 9),
  ('BR-2031', 14, 120),
  ('BR-2210', 11, 180),
  ('BR-2210', 8, 16),
  ('BR-2210', 7, 1)
) as v(code, stock_item_id, quantity)
join orders o on o.code = v.code;
