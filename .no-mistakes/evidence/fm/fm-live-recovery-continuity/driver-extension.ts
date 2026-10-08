import { writeFileSync, appendFileSync } from 'node:fs';
import { createBranchDispatchOffer, branchOfferForWake } from '../.pi/extensions/lib/fm-branch-dispatch.ts';
export default function(pi: any) {
  const home = process.env.FM_HOME!;
  const log = (x: any) => appendFileSync(home + '/driver.jsonl', JSON.stringify(x) + '\n');
  pi.on('session_start', () => { writeFileSync(home + '/state/.lock', process.pid + '\n'); log({started:process.pid}); });
  pi.registerCommand('lab-wake', {description:'Dispatch disposable heartbeat', handler: async (_:any,ctx:any) => {
    const routing = branchOfferForWake(home+'/state', 'heartbeat', false);
    const offer:any = createBranchDispatchOffer('heartbeat', routing.scope.projects, routing.heartbeat, routing.eligible, routing.awayOnly);
    pi.events.emit('fm-branch-supervision:dispatch', offer);
    log({accepted:offer.accepted});
    if(offer.accepted) offer.settlement.then(()=>{log({settled:'ok'});ctx.ui.notify('LAB wake settled');},(e:any)=>{log({settled:e.message});ctx.ui.notify('LAB '+e.message,'warning');});
  }});
  pi.registerCommand('lab-recover', {description:'Change main model to trigger real recovery',handler:async(_:any,ctx:any)=>{
    const model=ctx.modelRegistry.getAll().find((m:any)=>m.provider==='lab'&&m.id==='recovery');
    log({modelChanged:await pi.setModel(model)});
  }});
}
