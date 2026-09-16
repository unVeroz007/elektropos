-- Sertakan is_default pada search_products_v1 (dipakai kasir & scanner)
create or replace function public.search_products_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_query text := lower(trim(coalesce(p_input->>'query','')));
  v_limit integer := coalesce((p_input->>'limit')::integer, 25);
  v_result jsonb;
begin
  perform private.current_role();
  if length(v_query) > 120 or v_limit not between 1 and 100 then
    raise exception 'Batas pencarian tidak sah' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(x.payload order by x.name, x.id), '[]'::jsonb) into v_result from (
    select p.id, p.name,
      jsonb_build_object(
        'id', p.id, 'sku', p.sku, 'name', p.name, 'specification', p.specification,
        'base_unit', p.base_unit, 'shelf', p.shelf, 'track_segments', p.track_segments,
        'quantity_step', p.quantity_step::text,
        'units', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', u.id, 'label', u.label, 'factor_base', u.factor_base::text,
            'sale_step', u.sale_step::text, 'sell_price', u.sell_price::text,
            'is_default', u.is_default, 'version', u.version)
            order by u.is_default desc, u.label), '[]'::jsonb)
          from private.product_units u where u.product_id = p.id and u.active),
        'stock_shop', (select coalesce(sum(s.qty_base), 0)::text
          from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
          where l.product_id = p.id and s.location = 'SHOP' and s.condition = 'SALEABLE'),
        'stock_field', (select coalesce(sum(s.qty_base), 0)::text
          from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
          where l.product_id = p.id and s.location = 'FIELD_FATHER' and s.condition = 'SALEABLE')
      ) payload
    from private.products p
    where p.active and (
      v_query = ''
      or lower(p.name) like v_query || '%'
      or lower(p.name) like '%' || v_query || '%'
      or lower(p.sku) like v_query || '%'
      or lower(p.sku) = v_query
      or exists(select 1 from private.product_barcodes b where b.product_id = p.id and lower(b.code) = v_query)
      or exists(select 1 from unnest(p.aliases) a where lower(a) like '%' || v_query || '%')
    )
    order by p.name, p.id
    limit v_limit
  ) x;

  return v_result;
end $$;
revoke all on function public.search_products_v1(jsonb) from public,anon,authenticated;
grant execute on function public.search_products_v1(jsonb) to authenticated;
