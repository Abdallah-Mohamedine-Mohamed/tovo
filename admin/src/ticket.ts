/**
 * Le ticket d'une commande, pour une imprimante à tickets (02/11).
 *
 * Rouleau de 80 mm par défaut, 58 mm au choix. Passe par la fenêtre
 * d'impression du navigateur : toute imprimante installée sur le PC
 * (pilote Windows) convient. Noir sur blanc, gros caractères là où on lit
 * vite (numéro, total, adresse), rien qui ne serve au comptoir.
 */

export type LargeurTicket = 80 | 58;

type Fiche = Record<string, any>;

const echapper = (texte: unknown): string =>
  String(texte ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

const francs = (n: unknown) => `${Math.round(Number(n ?? 0)).toLocaleString('fr-FR').replace(/\s/g, ' ')} F`;

const heure = (iso: unknown) =>
  iso ? new Date(String(iso)).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '';

const telephone = (brut: unknown) => {
  const c = String(brut ?? '').replace(/\D/g, '');
  // « 22796123456 » se lit « +227 96 12 34 56 ».
  if (c.length === 11 && c.startsWith('227')) return `+227 ${c.slice(3).replace(/(\d{2})(?=\d)/g, '$1 ')}`;
  return c ? `+${c}` : '';
};

/** Le numéro court lu au comptoir et au téléphone : les 6 premiers caractères. */
export const numeroCourt = (id: unknown) => `#${String(id ?? '').replace(/-/g, '').slice(0, 6).toUpperCase()}`;

export function ticketHtml(fiche: Fiche, largeur: LargeurTicket = 80): string {
  const utile = largeur === 80 ? 72 : 48; // zone imprimable, en mm
  const corps = largeur === 80 ? 13 : 11.5;
  const articles = ((fiche.items ?? []) as Fiche[]).map((a) => `
    <tr>
      <td class="qte">${echapper(a.quantity)}×</td>
      <td>${echapper(a.name)}${a.options ? `<div class="opt">${echapper(a.options)}</div>` : ''}</td>
      <td class="prix">${francs(a.line_total)}</td>
    </tr>`).join('');
  const especes = fiche.payment_method === 'cash';
  const paye = fiche.payment_status === 'paid';
  const lignes = [
    fiche.pickup?.hint ? `<div class="bloc"><div class="etiq">Récupérer à</div><div class="fort">${echapper(fiche.pickup.hint)}</div></div>` : '',
    `<div class="bloc"><div class="etiq">Livrer à</div><div class="fort">${echapper(fiche.dropoff?.hint || '—')}</div></div>`,
  ].join('');

  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Commande ${numeroCourt(fiche.id)}</title>
<style>
@page { size: ${largeur}mm auto; margin: 0; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: #fff; color: #000; }
body { width: ${utile}mm; margin: 0 auto; padding: 3mm 0 6mm; font: ${corps}px/1.35 Arial, Helvetica, sans-serif; }
.centre { text-align: center; }
.marque { font-size: ${corps + 7}px; font-weight: 800; letter-spacing: 1px; }
.numero { font-size: ${corps + 11}px; font-weight: 800; margin: 1mm 0; }
.trait { border-top: 1px dashed #000; margin: 2.5mm 0; }
.etiq { font-size: ${corps - 2}px; text-transform: uppercase; letter-spacing: .5px; }
.fort { font-weight: 700; font-size: ${corps + 1}px; }
.bloc { margin: 1.5mm 0; }
table { width: 100%; border-collapse: collapse; }
td { vertical-align: top; padding: .8mm 0; }
td.qte { width: 9mm; font-weight: 700; }
td.prix { text-align: right; white-space: nowrap; padding-left: 2mm; }
.opt { font-size: ${corps - 2}px; }
.total td { font-size: ${corps + 5}px; font-weight: 800; padding-top: 1.5mm; }
.encaisser { margin-top: 2mm; padding: 1.5mm; border: 2px solid #000; text-align: center; font-weight: 800; font-size: ${corps + 1}px; }
.note { margin-top: 2mm; padding: 1.5mm; border: 1px solid #000; }
</style></head><body>
<div class="centre">
  <div class="marque">TOVO</div>
  <div class="numero">${numeroCourt(fiche.id)}</div>
  <div>${echapper(heure(fiche.placed_at))}</div>
  <div class="fort">${echapper(fiche.merchant?.name ?? 'Course')}</div>
</div>
<div class="trait"></div>
<div class="bloc"><div class="etiq">Client</div><div class="fort">${echapper(fiche.client?.name || '—')}</div><div>${echapper(telephone(fiche.client?.phone))}</div></div>
${lignes}
${fiche.driver?.name ? `<div class="bloc"><div class="etiq">Livreur</div><div>${echapper(fiche.driver.name)} ${echapper(telephone(fiche.driver.phone))}</div></div>` : ''}
<div class="trait"></div>
${articles ? `<table>${articles}</table><div class="trait"></div>` : ''}
<table>
  <tr><td>Articles</td><td class="prix">${francs(fiche.items_total)}</td></tr>
  <tr><td>Livraison</td><td class="prix">${francs(fiche.delivery_fee)}</td></tr>
  <tr class="total"><td>TOTAL</td><td class="prix">${francs(fiche.total)}</td></tr>
</table>
<div class="encaisser">${paye ? 'DÉJÀ PAYÉ' : especes ? `ESPÈCES À ENCAISSER<br>${francs(fiche.total)}` : 'PAIEMENT MOBILE EN ATTENTE'}</div>
${fiche.note ? `<div class="note"><div class="etiq">Note du client</div>${echapper(fiche.note)}</div>` : ''}
<div class="trait"></div>
<div class="centre">Merci ! Tovo · +227 76 76 20 20</div>
</body></html>`;
}

/**
 * Imprime le ticket sans quitter la page : un cadre invisible, la fenêtre
 * d'impression du navigateur, puis le cadre est retiré.
 */
export function imprimerTicket(fiche: Fiche, largeur: LargeurTicket = 80): void {
  const cadre = document.createElement('iframe');
  cadre.setAttribute('aria-hidden', 'true');
  cadre.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
  document.body.appendChild(cadre);
  const doc = cadre.contentDocument!;
  doc.open();
  doc.write(ticketHtml(fiche, largeur));
  doc.close();
  const lancer = () => {
    cadre.contentWindow?.focus();
    cadre.contentWindow?.print();
    window.setTimeout(() => cadre.remove(), 60_000);
  };
  // Laisser la mise en page se faire avant d'imprimer.
  window.setTimeout(lancer, 250);
}
