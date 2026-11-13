# Casa em dia

PWA em português para tarefas domésticas compartilhadas. Interface estática, Supabase Auth, PostgreSQL com RLS e RPCs, Web Push por Edge Function e agendamento por pg_cron.

## Usar

1. Abra o site e escolha **Criar minha casa online**. A demonstração é local e não grava exemplos no banco.
2. Crie uma conta com e-mail e senha, confirme o e-mail e entre.
3. Crie a casa e adicione os moradores. Compartilhe o código de convite apenas com eles.
4. Cada morador entra com sua conta, escolhe o perfil existente e vincula suas tarefas.
5. No celular, adicione à Tela de Início. Em Configurações, ative as notificações e faça o teste.

O GitHub Pages é público. Os dados da casa exigem login no Supabase e pertencimento à casa; o código de convite deve ser compartilhado apenas com os moradores. O endereço de produção é https://Rodrigo-Yuji.github.io/casa-em-dia/.

## Divisão de tarefas

Cada tarefa tem seu próprio rodízio, guiado por quem realmente a fez. Quem ainda não fez tem prioridade; depois, quem fez há mais tempo. Empates são resolvidos pela menor carga estimada do dia, menor número de tarefas, preferência inicial e ID estável. Quem cobre outra pessoa avança para o fim da fila daquela tarefa; o responsável mantém sua vez. Ausentes são pulados, mantêm sua prioridade ao retornar e não acumulam tarefas atrasadas. Se todos estiverem ausentes, a tarefa fica sem responsável.

A agenda futura simula conclusões pelos responsáveis previstos, por até 366 dias; coberturas e ausências alteram as previsões. Conclusões anteriores preservam o responsável e quem fez. O cliente envia o responsável exibido ao concluir; o banco rejeita uma conclusão se o rodízio tiver mudado, evitando registrar dívida contra a pessoa errada.

Coberturas são compensadas somente pela fila: quem realmente faz vai para o fim do rodízio; quem foi coberto mantém a próxima vez em que estiver disponível. Não existe dívida nem quitação adicional. O histórico preserva a tarefa, a data, o responsável e quem fez, apenas para reconhecer a participação e apoiar conversas. Registros antigos são preservados; não são convertidos em cobranças. Uma pessoa coberta não recebe duas tarefas no dia seguinte; recebe somente a próxima ocorrência da mesma tarefa.

As tarefas têm uma cor por morador (também identificadas pelo nome, sem depender apenas da cor), marcação de “Minha tarefa” e filtros com o nome de todos os moradores. A paleta é compartilhada e determinada pela ordem dos moradores da casa.

## Cadastro e e-mail

O aplicativo possui cadastro, login, tratamento do retorno de confirmação e solicitação de reenvio. A confirmação depende da configuração do Auth no Supabase e da entrega do provedor de e-mail. O sucesso de uma solicitação não comprova entrega. Configure o Site URL e os Redirect URLs com a origem publicada e use SMTP próprio para os moradores. Não foram desativadas confirmações nem confirmadas contas manualmente.

## Notificações e offline

O servidor verifica tarefas a cada minuto, considerando o fuso da casa (America/Sao_Paulo), a redistribuição por ausência e os horários. Envia uma vez por tarefa/data/dispositivo, com até três tentativas no intervalo de 15 minutos após o horário. Não recupera alertas de mais de 15 minutos atrás. Cada morador deve vincular sua conta e ativar notificações em cada aparelho.

No iPhone, Web Push exige iOS 16.4+ e abertura pelo ícone adicionado à Tela de Início. Foco, permissões, rede e decisões do sistema podem atrasar ou silenciar notificações. Web Push não equivale a um alarme de despertador e não garante som nem horário exato.

O service worker guarda os arquivos do aplicativo. Um cache por usuário permite consultar os últimos dados sincronizados sem conexão. Alterações online só são confirmadas depois da resposta do Supabase; não há fila de gravações offline. A demonstração usa armazenamento local separado. Nunca há fallback silencioso de uma gravação online para uma gravação local.

## Segurança

As tabelas públicas têm RLS e apenas leitura restrita à própria casa. As alterações passam por RPCs com escopo de casa e identidade autenticada. As chaves privadas VAPID e o segredo do agendador estão exclusivamente no schema privado do banco. A Edge Function autentica o agendador por segredo e os testes por Supabase Auth; seu verificador de JWT de gateway está desligado para permitir o agendador, com autenticação dentro da função. Nenhuma chave service_role está no cliente ou no repositório.

## Verificação

- `node --check app.js`
- `node --check sw.js`
- `node tests/client.cjs`
- `tests/database.sql`: cenários transacionais com rollback, sem dados de teste persistidos.

Os arquivos SQL em database/ são o histórico aplicado, em ordem: schema.sql, redistribution.sql, push.sql, reminder-schedule.sql, assignment-fix.sql, rotation-and-specific-favors.sql, validate-current-responsibility.sql, rotation-indexes.sql, rotation-without-extra-debt.sql. Não reaplicar em banco já migrado. As chaves de push foram provisionadas separadamente, sem incluir valores secretos no código.
