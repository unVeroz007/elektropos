-- cost_for_exit helper accepting lot_id
create or replace function private.cost_for_exit_lot(p_lot_id uuid, p_qty numeric)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_lot private.inventory_lots%rowtype; v_n numeric; v_d numeric; v_floor numeric; v_remainder numeric;
begin
  select * into v_lot from private.inventory_lots where id = p_lot_id;
  if not found then return 0; end if;
  if p_qty = v_lot.remaining_qty then return v_lot.remaining_cost; end if;
  if p_qty <= 0 or v_lot.remaining_qty <= 0 then return 0; end if;
  v_n := (v_lot.remaining_cost * 1000000)::numeric * (p_qty * 1000)::numeric;
  v_d := v_lot.remaining_qty * 1000;
  v_floor := trunc(v_n / v_d);
  v_remainder := mod(v_n, v_d);
  return (v_floor + case when 2 * v_remainder >= v_d then 1 else 0 end) / 1000000;
end $$;
revoke all on function private.cost_for_exit_lot(uuid, numeric) from public,anon,authenticated;