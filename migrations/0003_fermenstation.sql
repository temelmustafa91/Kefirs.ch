-- FermenStation : kéfir de fruits. Remplace le catalogue traiteur de démonstration.

delete from order_lines;
delete from order_stock;
delete from orders;
delete from stock_moves;
delete from recipe_lines;
delete from recipes;
delete from stock_items;

update shop set
  name = 'FermenStation',
  tagline = 'Kéfir de fruits. Découvrez la fermentation infinie.',
  announcement = 'Laissez le vide sidéral derrière vous. Les bouteilles partent au créneau, sans donner votre nom.',
  address = 'Station 7, quai des Ferments',
  open_time = '11:00',
  close_time = '14:00',
  evening_open = '17:30',
  evening_close = '20:00',
  slot_minutes = 30,
  slot_capacity = 12
where id = 1;

insert into stock_items (id, name, unit, quantity, threshold) values
  (1, 'Grains de kéfir', 'g', 800, 200),
  (2, 'Sucre de canne', 'g', 2400, 500),
  (3, 'Figues sèches', 'pièce', 40, 12),
  (4, 'Citron', 'pièce', 4, 8),
  (5, 'Gingembre', 'g', 90, 120),
  (6, 'Fruits rouges', 'g', 900, 200),
  (7, 'Hibiscus', 'g', 80, 20),
  (8, 'Menthe', 'g', 40, 15),
  (9, 'Pomme', 'g', 1200, 300),
  (10, 'Fruit de la passion', 'pièce', 18, 6),
  (11, 'Bouteilles', 'pièce', 36, 12),
  (12, 'Bouchons', 'pièce', 40, 12);

select setval('stock_items_id_seq', (select max(id) from stock_items));

insert into recipes (id, name, description, category, price_cents, prep_minutes, published, image, sort_order) values
  (1, 'Figue & citron', 'Le kéfir d''origine : figue sèche, citron, bulles fines.', 'Classique', 450, 5, true, 'figue', 1),
  (2, 'Gingembre', 'Racine fraîche et citron. Plus vif, plus pétillant.', 'Épicé', 480, 5, true, 'gingembre', 2),
  (3, 'Fruits rouges', 'Seconde fermentation sur framboises et mûres.', 'Fruits', 520, 5, true, 'rouges', 3),
  (4, 'Hibiscus', 'Fleur séchée, robe rose, peu sucré.', 'Floral', 480, 5, true, 'hibiscus', 4),
  (5, 'Pomme & menthe', 'Pomme verte et menthe, fermentation courte.', 'Fruits', 450, 5, true, 'pomme', 5),
  (6, 'Passion', 'Pulpe de passion, plus ronde, plus dorée.', 'Fruits', 550, 5, true, 'passion', 6);

select setval('recipes_id_seq', (select max(id) from recipes));

insert into recipe_lines (recipe_id, stock_item_id, quantity) values
  (1, 1, 8), (1, 2, 24), (1, 3, 1), (1, 4, 1), (1, 11, 1), (1, 12, 1),
  (2, 1, 8), (2, 2, 22), (2, 5, 18), (2, 4, 1), (2, 11, 1), (2, 12, 1),
  (3, 1, 8), (3, 2, 20), (3, 6, 45), (3, 11, 1), (3, 12, 1),
  (4, 1, 8), (4, 2, 18), (4, 7, 3), (4, 11, 1), (4, 12, 1),
  (5, 1, 8), (5, 2, 20), (5, 9, 60), (5, 8, 2), (5, 11, 1), (5, 12, 1),
  (6, 1, 8), (6, 2, 26), (6, 10, 1), (6, 11, 1), (6, 12, 1);

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
    ('FS-1842', 1, 0, '12:00', 'preparation', 'Bien frais', 1380),
    ('FS-1907', 1, 0, '12:30', 'recue', 'Sans pulpe', 1510),
    ('FS-2031', 1, 0, '18:30', 'prete', '', 1350),
    ('FS-2210', 2, 0, '12:00', 'recue', 'Bouteille consignée', 1490),
    ('FS-1044', 0, 1, '12:30', 'retiree', '', 480),
    ('FS-1108', 0, 2, '13:00', 'retiree', '', 900),
    ('FS-1215', 0, 3, '18:30', 'retiree', '', 1440),
    ('FS-1302', 0, 4, '12:00', 'retiree', '', 1520)
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
  ('FS-1842', 1, 'Figue & citron', 2, 450),
  ('FS-1842', 2, 'Gingembre', 1, 480),
  ('FS-1907', 6, 'Passion', 1, 550),
  ('FS-1907', 4, 'Hibiscus', 2, 480),
  ('FS-2031', 5, 'Pomme & menthe', 3, 450),
  ('FS-2210', 3, 'Fruits rouges', 2, 520),
  ('FS-2210', 1, 'Figue & citron', 1, 450),
  ('FS-1044', 2, 'Gingembre', 1, 480),
  ('FS-1108', 1, 'Figue & citron', 1, 450),
  ('FS-1108', 5, 'Pomme & menthe', 1, 450),
  ('FS-1215', 4, 'Hibiscus', 3, 480),
  ('FS-1302', 6, 'Passion', 1, 550),
  ('FS-1302', 3, 'Fruits rouges', 1, 520),
  ('FS-1302', 1, 'Figue & citron', 1, 450)
) as v(code, recipe_id, name, qty, unit_cents)
join orders o on o.code = v.code;

insert into order_stock (order_id, stock_item_id, quantity)
select o.id, v.stock_item_id, v.quantity
from (values
  ('FS-1842', 1, 24), ('FS-1842', 2, 70), ('FS-1842', 3, 2), ('FS-1842', 4, 3),
  ('FS-1842', 5, 18), ('FS-1842', 11, 3), ('FS-1842', 12, 3),
  ('FS-1907', 1, 24), ('FS-1907', 2, 62), ('FS-1907', 7, 6), ('FS-1907', 10, 1),
  ('FS-1907', 11, 3), ('FS-1907', 12, 3),
  ('FS-2031', 1, 24), ('FS-2031', 2, 60), ('FS-2031', 8, 6), ('FS-2031', 9, 180),
  ('FS-2031', 11, 3), ('FS-2031', 12, 3),
  ('FS-2210', 1, 24), ('FS-2210', 2, 64), ('FS-2210', 3, 1), ('FS-2210', 4, 1),
  ('FS-2210', 6, 90), ('FS-2210', 11, 3), ('FS-2210', 12, 3)
) as v(code, stock_item_id, quantity)
join orders o on o.code = v.code;
