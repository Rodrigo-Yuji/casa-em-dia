import { createClient } from "npm:@supabase/supabase-js@2.95.3";
import webpush from "npm:web-push@3.6.7";

Deno.serve(async (req) => {
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {auth:{persistSession:false,autoRefreshToken:false}});
  const { data: config, error: configError } = await admin.rpc("casa_push_config_service");
  const origin=req.headers.get("origin");
  const allowed = config && origin === new URL(config.site_url).origin;
  const headers: Record<string,string> = {"Content-Type":"application/json","Vary":"Origin"};
  if(allowed) headers["Access-Control-Allow-Origin"]=origin!;
  headers["Access-Control-Allow-Headers"]="authorization,apikey,content-type,x-client-info";
  headers["Access-Control-Allow-Methods"]="POST,OPTIONS";
  if(req.method==="OPTIONS") return new Response(null,{status:allowed?204:403,headers});
  const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
  if(configError||!config) return reply({error:"Configuração indisponível."},503);
  if(req.method!=="POST") return reply({error:"Método inválido."},405);
  if(origin&&!allowed) return reply({error:"Origem inválida."},403);
  let body; try{body=await req.json()}catch{return reply({error:"Corpo inválido."},400)}
  const cron=req.headers.get("x-casa-cron")===config.cron_token;
  let userId: string|undefined;
  if(!cron){
    const token=req.headers.get("authorization")?.replace(/^Bearer /i,"");
    if(!token) return reply({error:"Entre na sua conta."},401);
    const {data,error}=await admin.auth.getUser(token);
    if(error||!data.user) return reply({error:"Sessão inválida."},401);
    userId=data.user.id;
    if(body.test!==true) return reply({error:"Acesso restrito."},403);
  }
  webpush.setVapidDetails(config.site_url,config.vapid_public,config.vapid_private);
  const {data:rows,error}=await admin.rpc(cron?"casa_push_due":"casa_push_test_subscriptions",cron?{}:{p_user:userId});
  if(error) return reply({error:"Não foi possível consultar lembretes."},500);
  let sent=0,failed=0;
  for(const item of rows||[]){
    const endpointUrl=new URL(item.endpoint);
    const host=endpointUrl.hostname;
    if(endpointUrl.protocol!=="https:"||!(host==="fcm.googleapis.com"||host==="updates.push.services.mozilla.com"||host.endsWith(".push.apple.com")||host.endsWith(".notify.windows.com"))) {failed++;continue;}
    if(cron){
      const {data:claimed,error:claimError}=await admin.rpc("casa_push_claim",{p_subscription:item.subscription_id,p_task:item.task_id,p_date:item.occurrence_date});
      if(claimError||!claimed) continue;
    }
    const destination=new URL(config.site_url);
    if(cron&&item.household_id)destination.searchParams.set("house",item.household_id);
    if(cron&&item.control_id)destination.searchParams.set("control",item.control_id);
    destination.hash="hoje";
    const payload=JSON.stringify({title:cron?item.emoji+" Hora de cuidar da casa":"Casa em dia • Tudo certo!",body:cron?item.title+" — sua tarefa está te esperando.":"Os lembretes estão funcionando neste aparelho.",tag:cron?item.task_id+"-"+item.occurrence_date:"casa-test",url:destination.href});
    try{
      await webpush.sendNotification({endpoint:item.endpoint,keys:{p256dh:item.p256dh,auth:item.auth}},payload,{TTL:900,urgency:"high",timeout:10000});
      sent++;
      if(cron) await admin.rpc("casa_push_finish",{p_subscription:item.subscription_id,p_task:item.task_id,p_date:item.occurrence_date});
    }catch(e){
      failed++;
      const status=(e as {statusCode?:number}).statusCode;
      if(cron&&(status===410||status===404)) await admin.rpc("casa_push_finish",{p_subscription:item.subscription_id,p_task:item.task_id,p_date:item.occurrence_date,p_expired:true});
      console.error("Push delivery failed",status||"network");
    }
  }
  return reply({sent,failed});
});
