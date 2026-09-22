# GDC — Gestão de Atletas da Formação
### Documento de referência do projeto (arquitetura, decisões, armadilhas conhecidas)

Este documento existe para que qualquer pessoa (tu, outro programador, ou uma
IA numa conversa nova) consiga continuar este projeto sem precisar de
histórico de conversa anterior. Mantém-no atualizado sempre que fizeres
alterações estruturais.

---

## 1. Stack tecnológica

- **Frontend:** React (hooks) + Vite + Tailwind CSS + lucide-react (ícones).
  Sem bibliotecas de UI de terceiros — todos os componentes são feitos à medida.
- **Backend:** Supabase (Postgres + Auth + PostgREST + Edge Functions).
- **Ligação ao Supabase:** feita por `fetch()` direto às APIs REST do
  Supabase (`/rest/v1`, `/auth/v1`, `/functions/v1`) — **não** usa o SDK
  oficial `@supabase/supabase-js` no frontend (só é usado dentro da Edge
  Function, que corre em Deno). Isto foi uma escolha deliberada por uma
  limitação do ambiente onde o projeto começou a ser construído; qualquer
  alteração futura ao código deve continuar a seguir este padrão de `fetch`
  direto, a menos que se decida migrar para o SDK (mudança grande).
- **Email transacional:** Resend, chamado a partir de uma Edge Function.
- **Alojamento:** Vercel (deploy automático a partir do GitHub).
- **Formato:** PWA (instalável no telemóvel via browser), não é app nativa
  de loja.

---

## 2. Estrutura do repositório

```
package.json / vite.config.js / tailwind.config.js / postcss.config.js
index.html
public/
  manifest.json          <- ícone/nome da PWA
  icon-192.png, icon-512.png
src/
  main.jsx                <- ponto de entrada
  index.css                <- diretivas Tailwind
  App.jsx                  <- TODA a aplicação está aqui, num único ficheiro
.env.example                <- variáveis de ambiente opcionais (ver secção 5)
```

`App.jsx` é deliberadamente um único ficheiro grande (não dividido em muitos
componentes/pastas) para ser fácil de dar a uma IA numa conversa nova sem
perder contexto entre ficheiros.

---

## 3. Modelo de dados (Postgres / Supabase)

Tabelas principais: `profiles`, `teams`, `team_coaches`, `athletes`,
`events`, `attendance`, `incidents`, `call_ups`, `call_up_athletes`.

Conceitos-chave:

- **Perfis (`profiles.role`):** `pending` (conta criada, sem função ainda),
  `admin`, `coach`, `parent`. **O primeiro utilizador a criar conta no
  projeto torna-se automaticamente admin** (trigger `handle_new_user`).
- **Sem sistema de convites por email.** Qualquer pessoa cria conta
  livremente; o **admin** atribui manualmente a função (treinador de que
  equipa, ou encarregado de educação de que atleta) no separador
  "Utilizadores".
- **Atribuição automática por email:** se um treinador definir o email do
  encarregado de educação num atleta (`athletes.parent_email`) e já existir
  uma conta com esse email (pendente ou já encarregado de outro atleta),
  a ligação é feita na hora, sem precisar do admin. O mesmo acontece ao
  contrário: se alguém cria conta com um email que já estava à espera num
  atleta, fica logo ligado. Ver função `set_athlete_parent_email` e o
  trigger `handle_new_user`.
- **RLS (Row Level Security)** está ativo em todas as tabelas. As regras
  usam funções `security definer` (`is_admin()`, `is_coach_of_team()`,
  `is_parent_of_athlete()`, etc.) para evitar recursão infinita — **nunca
  escrevas uma política de RLS que faça uma subquery direta a outra tabela
  também protegida por RLS sem passar por uma função `security definer`**;
  já tivemos esse bug (ver secção 6).
- **Convocatórias:** um jogo só pode ter uma convocatória (`call_ups`,
  `event_id` é `unique`). Fica editável até à data do jogo (inclusive),
  mesmo depois de enviada. Reenviar só notifica por email quem mudou de
  estado desde o último envio (`call_ups.last_notified_athlete_ids`).

O esquema completo e atual (consolidado, não os incrementos históricos)
está em `gdc-schema-FULL-staging.sql` — usa esse ficheiro para criar
qualquer projeto Supabase novo de raiz (ex: um segundo ambiente de staging,
ou recuperação de desastre).

---

## 4. Edge Function

- **Nome exato:** `send-call-up-emails` (tem de corresponder exatamente ao
  que o código em `App.jsx` chama — já tivemos um bug por causa disto, ver
  secção 6).
- **"Verify JWT" tem de estar DESLIGADO** nas definições da função no
  Dashboard — a função já faz a sua própria verificação de autenticação
  por dentro; a verificação automática da plataforma bloqueia o pedido
  "preflight" do browser antes de chegar ao código.
- Segredos necessários (Edge Functions → Secrets): `RESEND_API_KEY`,
  `CALLUP_FROM_EMAIL`. `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` são
  injetados automaticamente pela plataforma, não precisam de ser definidos.
- Sempre que o código da função mudar, tem de se voltar a fazer **Deploy**
  manualmente no editor do Dashboard (não há deploy automático a partir do
  GitHub para Edge Functions neste projeto).

---

## 5. Variáveis de ambiente / ambientes

O `App.jsx` lê `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` das
variáveis de ambiente do Vite; se não estiverem definidas, usa os valores
de produção como valor por defeito (estão escritos no próprio código).

- **Produção:** projeto Vercel principal, branch `main`, sem variáveis de
  ambiente definidas (usa o fallback de produção automaticamente).
- **Staging:** segundo projeto Vercel, branch `staging`, com
  `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` definidas como **"Config"**
  (não "Secret" — são valores seguros para expor no browser) a apontar
  para um segundo projeto Supabase separado. Mostra uma barra vermelha
  "AMBIENTE DE TESTE" no topo quando ativo.
- URL/chave "anon" do Supabase **não são segredos** — a segurança real vem
  das políticas de RLS, não de esconder estes valores.

### Fluxo de trabalho para alterações futuras
1. Fazer upload/edição do ficheiro no branch **staging** do GitHub.
2. O Vercel de staging republica sozinho — testar lá primeiro.
3. Só depois de confirmado: GitHub → Pull Requests → New pull request
   (base `main`, compare `staging`) → Merge.
4. O Vercel de produção republica sozinho a partir do `main`.

---

## 6. Armadilhas já apanhadas (para não repetir)

- **RLS com recursão infinita:** duas tabelas cujas políticas se
  verificavam mutuamente por subquery direta. Corrigido envolvendo essas
  verificações em funções `security definer`.
- **RLS a verificar a própria linha ainda a ser criada:** uma política de
  INSERT que procurava a linha pelo seu próprio id falha, porque a linha
  ainda não existe nesse instante. Usar sempre uma coluna já presente no
  pedido (ex: `event_id`) em vez de procurar pelo `id` da própria linha.
- **Embeds do PostgREST:** uma relação um-para-um pode ser devolvida como
  objeto simples OU como array de um elemento, dependendo da direção da
  chave estrangeira. Código que lê um embed deve verificar
  `Array.isArray(...)` em vez de assumir sempre array.
- **"Failed to fetch" numa Edge Function:** normalmente é uma de duas
  causas — "Verify JWT" ligado (bloqueia o pedido preflight OPTIONS do
  browser antes do código correr), ou o nome da função publicada não
  corresponder exatamente ao que o `App.jsx` chama (o Dashboard sugere um
  nome aleatório tipo "rapid-function" se não for explicitamente escrito).
- **Confirm email / SMTP:** por defeito o Supabase não tem um servidor de
  email fiável para produção — é preciso configurar um SMTP próprio
  (usamos o Resend) tanto para os emails de autenticação (confirmação,
  recuperação de password) como, separadamente, a Edge Function usa o
  Resend diretamente para os emails de convocatória.
- **Definição "Production Branch" no Vercel:** já não fica em
  Settings → Git; está em Settings → Environments → Production →
  Branch Tracking (mudou de sítio numa atualização da Vercel).

---

## 7. Como continuar este projeto numa conversa nova

1. Vai ao GitHub, copia o conteúdo atual de `src/App.jsx`.
2. Anexa esse ficheiro (e este documento) numa conversa nova com uma IA
   (Claude ou outra) ou entrega-os a um programador.
3. Explica o que precisas de mudar. O código é extenso mas
   auto-contido — não há dependências escondidas fora deste ficheiro,
   das tabelas do Supabase, e da Edge Function.
4. Para alterações à base de dados, a IA/programador deve gerar um
   ficheiro SQL incremental (não recriar tudo) a aplicar no SQL Editor do
   Supabase — primeiro em staging, só depois em produção.
