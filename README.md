# Painel de Despesas · Trade Marketing

Painel web para acompanhar as despesas de Trade Marketing (eventos, feiras e ações) a partir do relatório de despesas exportado do SAP.

- **Acesso com login.** Só e-mails liberados pelo administrador veem os dados.
- **Importação mensal.** Um editor envia a planilha do mês (.xlsx, aba Base). Os meses da planilha substituem os mesmos meses já gravados, sem duplicar.
- **Análise.** Indicadores, evolução mensal, unidades de negócio, áreas, centros de custo e fornecedores, com filtros.
- **Exportação.** PDF, Excel e PowerPoint para apresentação.

## Estrutura

| Arquivo | O que é |
|---|---|
| `index.html` | O painel completo (um único arquivo, abre no navegador) |
| `supabase/01_estrutura_trade_marketing.sql` | Tabelas, regras de classificação, importação e segurança do banco |

## Tecnologia

HTML e JavaScript puro, com Supabase (banco e login), SheetJS, Chart.js, jsPDF e PptxGenJS carregados por CDN. Não há etapa de build.

## Segurança

A chave do Supabase que aparece no `index.html` é a chave pública. O acesso aos dados é controlado no banco por login e regras de segurança por linha (RLS). Nenhum dado de despesa fica guardado neste repositório.
