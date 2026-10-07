/* =====================================================================
   PAINEL TRADE MARKETING · MOVIDA
   Estrutura do banco de dados (Supabase / PostgreSQL)

   Como usar: no Supabase, abra "SQL Editor" > "New query", cole este
   arquivo inteiro e clique em "Run". Pode rodar de novo sem problema:
   o script apaga e recria apenas as funções e visões, nunca os dados.

   O que este script cria:
     1. acessos ........ quem pode entrar no painel e com qual papel
     2. importacoes .... histórico de cada planilha do SAP carregada
     3. lancamentos .... os lançamentos (uma linha por linha da aba Base)
     4. regras de natureza e fornecedor, iguais às do painel
     5. funções de importação (iniciar, concluir, cancelar)
     6. visões de leitura e de conferência
     7. segurança (RLS): só quem está em "acessos" vê os dados
   ===================================================================== */


/* ---------------------------------------------------------------------
   1) ACESSOS
   Lista de e-mails autorizados. Papéis:
     leitor ... vê o painel
     editor ... vê o painel e importa planilhas
     admin .... tudo acima e gerencia a lista de acessos
   --------------------------------------------------------------------- */
create table if not exists public.acessos (
  email      text primary key check (email = lower(btrim(email))),
  nome       text,
  papel      text not null default 'leitor' check (papel in ('leitor','editor','admin')),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);
comment on table public.acessos is 'E-mails autorizados a usar o painel de Trade Marketing e o papel de cada um.';

-- Papel do usuário logado (null = sem acesso). Usada pelas regras de segurança.
create or replace function public.meu_papel()
returns text
language sql stable security definer
set search_path = ''
as $$
  select a.papel
    from public.acessos a
   where a.ativo
     and a.email = lower(coalesce(auth.jwt() ->> 'email', ''))
$$;
comment on function public.meu_papel() is 'Papel do usuário logado em acessos (leitor, editor, admin) ou null.';


/* ---------------------------------------------------------------------
   2) IMPORTAÇÕES
   Cada planilha carregada vira uma importação. Ao concluir, os meses
   presentes na planilha SUBSTITUEM os mesmos meses das importações
   anteriores. Assim, carregar Vendas_40 (jan a out) depois de
   Vendas_39 (jan a set) não duplica nada.
   --------------------------------------------------------------------- */
create table if not exists public.importacoes (
  id            bigint generated always as identity primary key,
  arquivo       text not null,
  periodos      text[] not null default '{}',
  linhas        integer not null default 0,
  total         numeric(18,2),
  status        text not null default 'carregando'
                check (status in ('carregando','concluida','substituida','cancelada')),
  criado_por    text default lower(auth.jwt() ->> 'email'),
  criado_em     timestamptz not null default now(),
  concluido_em  timestamptz,
  observacao    text
);
comment on table public.importacoes is 'Histórico das planilhas do SAP carregadas no banco.';


/* ---------------------------------------------------------------------
   3) LANÇAMENTOS
   Guarda as colunas originais da aba Base (para auditoria e para
   reclassificar no futuro) e os campos calculados pelo painel.
   --------------------------------------------------------------------- */
create table if not exists public.lancamentos (
  id                   bigint generated always as identity primary key,
  importacao_id        bigint not null references public.importacoes(id) on delete cascade,

  -- Período no formato AAAA-MM (vem de Ano/Mês; se faltar, da data de lançamento)
  per                  text not null check (per ~ '^\d{4}-\d{2}$' or per = 'sem-data'),

  -- Colunas originais da exportação do SAP
  empresa              text,
  conta                text,
  data_lancamento      date,
  data_documento       date,
  n_documento          text,
  atribuicao           text,
  tipo_documento       text,
  valor                numeric(18,2) not null,   -- Montante em moeda interna
  centro_lucro         text,
  centro_custo         text,
  texto                text,
  texto_cabecalho      text,                     -- Texto cabeçalho documento
  fornecedor_sap       text,                     -- Código Fornecedor e Descrição
  material_sap         text,                     -- Código Material e Descrição
  criado_por_sap       text,                     -- Criado por:
  conta_contrapartida  text,                     -- Conta lnçto.contrap.
  estorno_com          text,
  grupo                text,                     -- Grupo de despesa
  area                 text,                     -- CCUSTO_GRUPO
  agrupamento          text,                     -- CCUSTO_AGRUPAMENTO
  criterio_rateio      text,                     -- CRITERIO_RATEIO

  -- Valor rateado por unidade de negócio
  rac  numeric not null default 0,
  zkm  numeric not null default 0,
  gtf  numeric not null default 0,
  sn   numeric not null default 0,
  sat  numeric not null default 0,
  doh  numeric not null default 0,
  cs   numeric not null default 0,

  -- Calculados automaticamente pelo gatilho (seção 4)
  nat        text check (nat in ('NF','DIR','REC','PROV')),
  forn_cod   text,
  forn_nome  text,

  criado_em  timestamptz not null default now()
);
comment on table public.lancamentos is 'Lançamentos de despesas de Trade Marketing (aba Base da exportação do SAP).';
comment on column public.lancamentos.nat is 'NF = nota fiscal, DIR = despesa direta, REC = reclassificação, PROV = provisão e ajuste. Calculado pelo gatilho.';

create index if not exists lancamentos_importacao_idx on public.lancamentos (importacao_id);
create index if not exists lancamentos_per_idx        on public.lancamentos (per);
create index if not exists lancamentos_nat_idx        on public.lancamentos (nat);
create index if not exists lancamentos_forn_idx       on public.lancamentos (forn_cod);


/* ---------------------------------------------------------------------
   4) REGRAS DE NEGÓCIO (iguais às funções natureza() e fornecedor()
      do painel). Rodam sozinhas a cada linha gravada.
   --------------------------------------------------------------------- */

-- Remove acentos, passa para minúsculas e junta espaços (igual ao norm() do painel)
create or replace function public.tm_norm(s text)
returns text
language sql immutable
set search_path = ''
as $$
  select btrim(regexp_replace(
           lower(regexp_replace(normalize(coalesce(s,''), NFD), '[̀-ͯ]', '', 'g')),
           '[\s ]+', ' ', 'g'))
$$;

-- Natureza do lançamento, na mesma ordem do painel
create or replace function public.tm_natureza(p_texto text, p_cab text, p_atrib text, p_tipo text)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  t  text := public.tm_norm(p_texto);
  h  text := public.tm_norm(p_cab);
  a  text := public.tm_norm(p_atrib);
  tp text := upper(coalesce(p_tipo,''));
begin
  -- 1. Reclassificação
  if t like '%reclass%' or h like '%reclass%' or a like '%reclass%' then return 'REC'; end if;
  -- 2. Provisão e ajustes
  if t like 'prov%' or a like 'prov%' or h like 'provis%' then return 'PROV'; end if;
  -- 3. Nota fiscal: "NF" como palavra no texto, ou tipo RE
  if t ~ '(^|[^a-z0-9_])nf([^a-z0-9_]|$)' or tp = 'RE' then return 'NF'; end if;
  -- 4. Estornos manuais de provisão
  if tp in ('ZD','ZL') then return 'PROV'; end if;
  -- 5. Todo o resto
  return 'DIR';
end;
$$;

-- Fornecedor: código de 10 dígitos no Texto; se não houver, a coluna do SAP
create or replace function public.tm_fornecedor(p_texto text, p_forn_sap text, out cod text, out nome text)
language plpgsql immutable
set search_path = ''
as $$
declare m text[];
begin
  m := regexp_match(coalesce(p_texto,''), '(?:^|\s)(\d{10})\s*-?\s+(.+)$');
  if m is not null then
    cod := m[1]; nome := btrim(m[2]); return;
  end if;
  m := regexp_match(coalesce(p_forn_sap,''), '^\s*(\d{6,})\s*-\s*(.+)$');
  if m is not null then
    cod := lpad(m[1], 10, '0'); nome := btrim(m[2]); return;
  end if;
end;
$$;

-- Gatilho: preenche nat, forn_cod e forn_nome
create or replace function public.tm_classificar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare f record;
begin
  new.nat := public.tm_natureza(new.texto, new.texto_cabecalho, new.atribuicao, new.tipo_documento);
  f := public.tm_fornecedor(new.texto, new.fornecedor_sap);
  new.forn_cod  := f.cod;
  new.forn_nome := f.nome;
  return new;
end;
$$;

drop trigger if exists lancamentos_classificar on public.lancamentos;
create trigger lancamentos_classificar
  before insert or update of texto, texto_cabecalho, atribuicao, tipo_documento, fornecedor_sap
  on public.lancamentos
  for each row execute function public.tm_classificar();


/* ---------------------------------------------------------------------
   5) IMPORTAÇÃO
   O painel faz assim:
     a) iniciar_importacao('Vendas_40.xlsx', '{2026-01,...,2026-10}')  -> id
     b) grava os lançamentos em lotes, com importacao_id = id
     c) concluir_importacao(id)
   Enquanto não conclui, nada aparece no painel. Se der erro no meio,
   cancelar_importacao(id) apaga o que foi gravado.
   --------------------------------------------------------------------- */
create or replace function public.iniciar_importacao(p_arquivo text, p_periodos text[])
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare v_id bigint;
begin
  if coalesce(public.meu_papel(),'') not in ('editor','admin') then
    raise exception 'Seu usuário não tem permissão para importar planilhas.';
  end if;
  if p_periodos is null or cardinality(p_periodos) = 0 then
    raise exception 'A planilha não tem nenhum mês identificado.';
  end if;

  -- Limpa importações abandonadas há mais de 1 dia
  update public.importacoes set status = 'cancelada', observacao = 'Abandonada (não concluída)'
   where status = 'carregando' and criado_em < now() - interval '1 day';
  delete from public.lancamentos l using public.importacoes i
   where l.importacao_id = i.id and i.status = 'cancelada';

  insert into public.importacoes (arquivo, periodos, criado_por)
  values (p_arquivo, (select array_agg(distinct p order by p) from unnest(p_periodos) p),
          lower(auth.jwt() ->> 'email'))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.concluir_importacao(p_id bigint)
returns public.importacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_imp   public.importacoes;
  v_lin   integer;
  v_tot   numeric;
  v_per   text[];
begin
  if coalesce(public.meu_papel(),'') not in ('editor','admin') then
    raise exception 'Seu usuário não tem permissão para importar planilhas.';
  end if;

  -- Uma importação por vez
  perform pg_advisory_xact_lock(hashtext('tm_importacao'));

  select * into v_imp from public.importacoes where id = p_id for update;
  if not found then raise exception 'Importação % não encontrada.', p_id; end if;
  if v_imp.status <> 'carregando' then
    raise exception 'A importação % já está com status "%".', p_id, v_imp.status;
  end if;

  select count(*), coalesce(sum(valor),0), array_agg(distinct per order by per)
    into v_lin, v_tot, v_per
    from public.lancamentos where importacao_id = p_id;
  if v_lin = 0 then raise exception 'Nenhum lançamento foi gravado nesta importação.'; end if;

  -- Os meses da nova planilha substituem os mesmos meses das anteriores
  delete from public.lancamentos l
   using public.importacoes i
   where l.importacao_id = i.id
     and i.id <> p_id
     and i.status = 'concluida'
     and l.per = any (v_per);

  -- Importações antigas que ficaram vazias passam a "substituida"
  update public.importacoes i
     set status = 'substituida',
         observacao = 'Substituída pela importação ' || p_id || ' (' || v_imp.arquivo || ')'
   where i.status = 'concluida'
     and i.id <> p_id
     and not exists (select 1 from public.lancamentos l where l.importacao_id = i.id);

  update public.importacoes
     set status = 'concluida', linhas = v_lin, total = v_tot,
         periodos = v_per, concluido_em = now()
   where id = p_id
  returning * into v_imp;

  return v_imp;
end;
$$;

create or replace function public.cancelar_importacao(p_id bigint)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if coalesce(public.meu_papel(),'') not in ('editor','admin') then
    raise exception 'Seu usuário não tem permissão para importar planilhas.';
  end if;
  delete from public.lancamentos where importacao_id = p_id
     and exists (select 1 from public.importacoes where id = p_id and status = 'carregando');
  update public.importacoes set status = 'cancelada', observacao = 'Cancelada pelo usuário'
   where id = p_id and status = 'carregando';
end;
$$;

-- Reaplica as regras de natureza e fornecedor em toda a base
-- (use se as regras mudarem no futuro). Só admin.
create or replace function public.reclassificar_tudo()
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare n integer;
begin
  if coalesce(public.meu_papel(),'') <> 'admin' then
    raise exception 'Apenas administradores podem reclassificar a base.';
  end if;
  update public.lancamentos l
     set nat       = public.tm_natureza(l.texto, l.texto_cabecalho, l.atribuicao, l.tipo_documento),
         forn_cod  = (public.tm_fornecedor(l.texto, l.fornecedor_sap)).cod,
         forn_nome = (public.tm_fornecedor(l.texto, l.fornecedor_sap)).nome
   where true;
  get diagnostics n = row_count;
  return n;
end;
$$;


/* ---------------------------------------------------------------------
   6) VISÕES (o que o painel lê)
   Todas respeitam a segurança do usuário logado (security_invoker).
   --------------------------------------------------------------------- */

-- Lançamentos válidos (só de importações concluídas)
drop view if exists public.v_conferencia, public.v_resumo_mensal, public.v_fornecedores, public.v_lancamentos;

create view public.v_lancamentos with (security_invoker = true) as
select l.id, l.per, l.valor, l.grupo, l.area, l.agrupamento, l.centro_custo, l.conta,
       l.tipo_documento, l.nat, l.forn_cod, l.forn_nome, l.texto, l.texto_cabecalho,
       l.atribuicao, l.data_lancamento, l.n_documento, l.criterio_rateio,
       l.rac, l.zkm, l.gtf, l.sn, l.sat, l.doh, l.cs,
       l.importacao_id
  from public.lancamentos l
  join public.importacoes i on i.id = l.importacao_id and i.status = 'concluida';
comment on view public.v_lancamentos is 'Lançamentos de importações concluídas. É a fonte do painel.';

-- Fornecedores com o nome mais frequente (nas NFs pesa 10x, como no painel)
create view public.v_fornecedores with (security_invoker = true) as
with grafias as (
  select forn_cod,
         regexp_replace(forn_nome, '\s+', ' ', 'g') as nome,
         sum(case when nat = 'NF' then 10 else 1 end) as peso
    from public.v_lancamentos
   where forn_cod is not null
   group by 1, 2
), escolhido as (
  select distinct on (forn_cod) forn_cod,
         regexp_replace(nome, '\s+(e|de|da|do|-)$', '', 'i') as nome
    from grafias
   order by forn_cod, peso desc, length(nome) desc
)
select e.forn_cod, e.nome,
       sum(l.valor) filter (where l.nat <> 'PROV') as realizado,
       sum(l.valor) as contabil,
       count(*)     as lancamentos
  from escolhido e
  join public.v_lancamentos l using (forn_cod)
 group by e.forn_cod, e.nome;
comment on view public.v_fornecedores is 'Um nome por código de fornecedor, com totais realizado e contábil.';

-- Resumo por mês, grupo e natureza
create view public.v_resumo_mensal with (security_invoker = true) as
select per, grupo, nat, count(*) as lancamentos, sum(valor) as valor
  from public.v_lancamentos
 group by per, grupo, nat;

-- Números para conferir com o painel (seção 7 do LEIA-ME)
create view public.v_conferencia with (security_invoker = true) as
select count(*)                                                 as lancamentos,
       sum(valor) filter (where nat in ('NF','DIR','REC'))      as realizado,
       sum(valor) filter (where nat = 'NF')                     as notas_fiscais,
       sum(valor) filter (where nat = 'DIR')                    as despesas_diretas,
       sum(valor) filter (where nat = 'REC')                    as reclassificacoes,
       sum(valor) filter (where nat = 'PROV')                   as provisoes,
       sum(valor)                                               as contabil,
       min(per) filter (where per <> 'sem-data')                as primeiro_mes,
       max(per) filter (where per <> 'sem-data')                as ultimo_mes
  from public.v_lancamentos;


/* ---------------------------------------------------------------------
   7) SEGURANÇA (Row Level Security)
   Ninguém anônimo lê nada. Usuário logado só lê se estiver em "acessos".
   Gravar lançamentos: só editor/admin, e só em importação "carregando".
   --------------------------------------------------------------------- */
alter table public.acessos     enable row level security;
alter table public.importacoes enable row level security;
alter table public.lancamentos enable row level security;

revoke all on public.acessos, public.importacoes, public.lancamentos from anon;
revoke all on public.v_lancamentos, public.v_fornecedores, public.v_resumo_mensal, public.v_conferencia from anon;
revoke execute on function public.meu_papel(), public.iniciar_importacao(text, text[]),
       public.concluir_importacao(bigint), public.cancelar_importacao(bigint),
       public.reclassificar_tudo() from public, anon;

grant select, insert, update, delete on public.acessos to authenticated;
grant select on public.importacoes to authenticated;
grant select, insert on public.lancamentos to authenticated;
grant select on public.v_lancamentos, public.v_fornecedores, public.v_resumo_mensal, public.v_conferencia to authenticated;
grant execute on function public.meu_papel(), public.iniciar_importacao(text, text[]),
       public.concluir_importacao(bigint), public.cancelar_importacao(bigint),
       public.reclassificar_tudo() to authenticated;

-- acessos: cada um vê a própria linha; admin vê e altera todas
drop policy if exists acessos_ler on public.acessos;
create policy acessos_ler on public.acessos for select to authenticated
  using (email = lower(auth.jwt() ->> 'email') or public.meu_papel() = 'admin');

drop policy if exists acessos_admin on public.acessos;
create policy acessos_admin on public.acessos for all to authenticated
  using (public.meu_papel() = 'admin') with check (public.meu_papel() = 'admin');

-- importacoes: qualquer usuário com acesso lê (gravação só pelas funções)
drop policy if exists importacoes_ler on public.importacoes;
create policy importacoes_ler on public.importacoes for select to authenticated
  using (public.meu_papel() is not null);

-- lancamentos: leitura para quem tem acesso
drop policy if exists lancamentos_ler on public.lancamentos;
create policy lancamentos_ler on public.lancamentos for select to authenticated
  using ((select public.meu_papel()) is not null);

-- lancamentos: gravação só por editor/admin, numa importação em andamento
drop policy if exists lancamentos_gravar on public.lancamentos;
create policy lancamentos_gravar on public.lancamentos for insert to authenticated
  with check (
    (select public.meu_papel()) in ('editor','admin')
    and exists (select 1 from public.importacoes i
                 where i.id = importacao_id and i.status = 'carregando')
  );


/* ---------------------------------------------------------------------
   8) PRIMEIRO ADMINISTRADOR
   Troque o e-mail abaixo pelo seu antes de rodar (ou rode depois,
   separado). Sem isso ninguém consegue ver os dados.
   --------------------------------------------------------------------- */
insert into public.acessos (email, nome, papel)
values ('thaysscosta@gmail.com', 'Administrador', 'admin')
on conflict (email) do update set papel = 'admin', ativo = true;
