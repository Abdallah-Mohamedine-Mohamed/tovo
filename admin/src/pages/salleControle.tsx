import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import { Alert, App as AntdApp, Button, Switch } from 'antd';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { appelerBackend } from '../backend';
import { supabaseClient } from '../supabaseClient';
import { FicheCommande } from './orderDetail';

/**
 * La salle de contrôle (maquette validée le 02/11) : ce qu'il faut voir et
 * faire, maintenant. Les règles sont au serveur (services/salleControle.ts) ;
 * cet écran relit toutes les 15 secondes, et dès qu'une commande change.
 *
 * Une alerte nouvelle sonne (si le son est activé : un navigateur ne joue
 * rien tant qu'on n'a pas touché la page).
 *
 * Une NOUVELLE COMMANDE (02/11, demande du fondateur) : un carillon distinct
 * des bips d'alerte, une fenêtre en haut à droite qui reste 5 minutes ou
 * jusqu'à ce que la commande soit acceptée, une notification Windows si
 * l'onglet est caché, et le titre de l'onglet qui compte celles non vues.
 */

type Gravite = 'rouge' | 'orange' | 'gris';

interface Salle {
  le: string;
  chiffres: {
    commandes: number; en_cours: number; en_cours_a_traiter: number; livrees: number;
    duree_mediane_min: number | null; annulees: number;
    motifs_annulation: { motif: string; nombre: number }[];
    chiffre_affaires: number; livraison: number;
    livreurs_en_ligne: number; livreurs_total: number; livreurs_libres: number;
  };
  alertes: {
    id: string; type: string; gravite: Gravite; titre: string; detail: string;
    depuis_min: number; commande_id: string | null;
    action: { libelle: string; tel?: string | null; page?: string };
  }[];
  en_cours: {
    id: string; boutique: string; client: string; lieu: string; total: number; etape: number;
    statut: string; livreur: string | null; age_min: number; en_alerte: boolean;
  }[];
  boutiques: {
    id: string; nom: string; ouverte: boolean; commandes: number;
    delai_acceptation_min: number | null; annulees: number; note: string | null;
  }[];
  livreurs: { id: string; nom: string; tel: string | null; etat: string; detail: string; courses_du_jour: number }[];
  carte: {
    commandes: { id: string; lat: number; lng: number; en_alerte: boolean; depart: { lat: number; lng: number } | null; titre: string }[];
    boutiques: { id: string; nom: string; lat: number; lng: number; ouverte: boolean }[];
    livreurs: { id: string; nom: string; lat: number; lng: number; en_course: boolean }[];
  };
}

const INK = '#14201E';
const DOUX = '#55615D';
const GRIS = '#7A8581';
const ROUGE = '#D94C45';
const ROUGE_TEXTE = '#A8322C';
const ORANGE = '#B86A12';
const VERT = '#168A63';
const BLEU = '#2F6FD6';
const FOND_GRAVITE: Record<Gravite, string> = { rouge: '#FBE9E8', orange: '#FCF1E3', gris: '#F4F5F2' };
const POINT_GRAVITE: Record<Gravite, string> = { rouge: ROUGE, orange: ORANGE, gris: DOUX };

const francs = (n: number) => `${Math.round(n).toLocaleString('fr-FR').replace(/\s/g, ' ')} F`;
const telephone = (brut?: string | null) => {
  const c = (brut ?? '').replace(/\D/g, '');
  return c ? `+${c}` : null;
};

const carteStyle: React.CSSProperties = { background: '#FFFFFF', borderRadius: 18, padding: 18 };
const titre2: React.CSSProperties = { margin: 0, fontSize: 17, fontWeight: 700 };

/** Deux bips courts, sans fichier son. */
function sonner() {
  try {
    const ctx = new AudioContext();
    [0, 0.25].forEach((debut) => {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.0001, ctx.currentTime + debut);
      gain.gain.exponentialRampToValueAtTime(0.3, ctx.currentTime + debut + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + debut + 0.18);
      osc.connect(gain).connect(ctx.destination);
      osc.start(ctx.currentTime + debut);
      osc.stop(ctx.currentTime + debut + 0.2);
    });
  } catch {
    // Pas de son possible : l'écran suffit.
  }
}

/** Le carillon d'une nouvelle commande : deux notes douces, montantes. */
function carillon() {
  try {
    const ctx = new AudioContext();
    const notes: Array<[number, number]> = [[660, 0], [990, 0.18]];
    for (const [frequence, debut] of notes) {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = frequence;
      gain.gain.setValueAtTime(0.0001, ctx.currentTime + debut);
      gain.gain.exponentialRampToValueAtTime(0.25, ctx.currentTime + debut + 0.03);
      gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + debut + 0.6);
      osc.connect(gain).connect(ctx.destination);
      osc.start(ctx.currentTime + debut);
      osc.stop(ctx.currentTime + debut + 0.65);
    }
  } catch {
    // Pas de son possible : la fenêtre suffit.
  }
}

/** « 40130 min » ne se lit pas : 12 min, 3 h 20, 27 j. */
export function dureeLisible(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  if (minutes < 24 * 60) {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return m ? `${h} h ${String(m).padStart(2, '0')}` : `${h} h`;
  }
  return `${Math.floor(minutes / (24 * 60))} j`;
}

const TITRE_ONGLET = 'Tovo — Salle de contrôle';
/** La fenêtre d'une nouvelle commande reste 5 minutes, sauf si quelqu'un agit avant. */
const DUREE_FENETRE_S = 5 * 60;

export function SalleControle() {
  const naviguer = useNavigate();
  const [salle, setSalle] = useState<Salle | null>(null);
  const [erreur, setErreur] = useState<string | null>(null);
  const [son, setSon] = useState(() => localStorage.getItem('salle-son') === 'oui');
  const dejaVues = useRef<Set<string> | null>(null);
  const { notification } = AntdApp.useApp();
  // Les commandes déjà connues (null : premier chargement, rien ne sonne).
  const commandesVues = useRef<Set<string> | null>(null);
  // Les fenêtres ouvertes, refermées dès que la commande est acceptée.
  const fenetres = useRef<Set<string>>(new Set());
  const sonRef = useRef(son);
  sonRef.current = son;
  const [nonVues, setNonVues] = useState(0);
  // La fiche d'une commande s'ouvre ici, sans quitter la salle.
  const [fiche, setFiche] = useState<string | null>(null);

  /** Les commandes jamais vues : carillon, fenêtre, notification, titre. */
  const annoncerLesNouvelles = (donnees: Salle) => {
    const actuelles = new Map(donnees.en_cours.map((o) => [o.id, o]));
    // Une commande acceptée (ou disparue) ferme sa fenêtre : quelqu'un a agi.
    for (const id of [...fenetres.current]) {
      const o = actuelles.get(id);
      if (!o || o.etape > 0) {
        notification.destroy(`commande:${id}`);
        fenetres.current.delete(id);
      }
    }
    const premiere = commandesVues.current === null;
    const nouvelles = premiere ? [] : donnees.en_cours.filter((o) => !commandesVues.current!.has(o.id));
    commandesVues.current = new Set(actuelles.keys());
    if (!nouvelles.length) return;
    if (sonRef.current) carillon();
    for (const o of nouvelles) {
      const cle = `commande:${o.id}`;
      const texte = `${o.boutique} → ${o.lieu} · ${francs(o.total)} · ${o.client}`;
      fenetres.current.add(o.id);
      notification.open({
        key: cle,
        placement: 'topRight',
        duration: DUREE_FENETRE_S,
        message: <span style={{ fontWeight: 700 }}>Nouvelle commande</span>,
        description: texte,
        btn: (
          <Button
            type="primary"
            onClick={() => {
              notification.destroy(cle);
              fenetres.current.delete(o.id);
              setFiche(o.id);
            }}
          >
            Voir
          </Button>
        ),
        onClose: () => fenetres.current.delete(o.id),
      });
      // L'onglet est caché : Windows prévient, si on l'a autorisé.
      if (document.hidden && 'Notification' in window && Notification.permission === 'granted') {
        const n = new Notification('Nouvelle commande', { body: texte, tag: cle });
        n.onclick = () => {
          window.focus();
          setFiche(o.id);
          n.close();
        };
      }
    }
    if (document.hidden) setNonVues((v) => v + nouvelles.length);
  };
  // Toujours la dernière version, sans recréer la lecture ni l'abonnement.
  const annoncerRef = useRef(annoncerLesNouvelles);
  annoncerRef.current = annoncerLesNouvelles;

  // Le titre de l'onglet compte les commandes arrivées pendant qu'on regardait ailleurs.
  useEffect(() => {
    document.title = nonVues
      ? `(${nonVues}) ${nonVues > 1 ? 'Nouvelles commandes' : 'Nouvelle commande'} — Tovo`
      : TITRE_ONGLET;
  }, [nonVues]);
  useEffect(() => {
    const revenir = () => {
      if (!document.hidden) setNonVues(0);
    };
    document.addEventListener('visibilitychange', revenir);
    window.addEventListener('focus', revenir);
    return () => {
      document.removeEventListener('visibilitychange', revenir);
      window.removeEventListener('focus', revenir);
      document.title = 'Tovo — Administration';
    };
  }, []);

  const charger = useCallback(async () => {
    try {
      const donnees = await appelerBackend<Salle>('GET', '/admin/controle');
      setSalle(donnees);
      setErreur(null);
      // Une alerte jamais vue sonne ; au premier chargement, on ne sonne pas
      // pour ce qui était déjà là.
      const ids = new Set(donnees.alertes.map((a) => a.id));
      if (dejaVues.current && sonRef.current && [...ids].some((id) => !dejaVues.current!.has(id))) sonner();
      dejaVues.current = ids;
      annoncerRef.current(donnees);
    } catch (e) {
      setErreur(e instanceof Error ? e.message : 'Lecture impossible.');
    }
  }, []);

  useEffect(() => {
    void charger();
    const minuterie = window.setInterval(() => void charger(), 15_000);
    // Une commande qui change : on relit tout de suite (au plus une fois par seconde).
    let attente: number | undefined;
    const canal = supabaseClient
      .channel('salle-controle')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => {
        window.clearTimeout(attente);
        attente = window.setTimeout(() => void charger(), 1000);
      })
      .subscribe();
    return () => {
      window.clearInterval(minuterie);
      window.clearTimeout(attente);
      void supabaseClient.removeChannel(canal);
    };
  }, [charger]);

  const basculerSon = (oui: boolean) => {
    setSon(oui);
    localStorage.setItem('salle-son', oui ? 'oui' : 'non');
    if (oui) {
      carillon();
      // Le bon moment pour demander les notifications Windows : un geste.
      if ('Notification' in window && Notification.permission === 'default') void Notification.requestPermission();
    }
  };

  const maj = salle ? new Date(salle.le).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '—';
  const enDirect = !!salle && !erreur;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20, color: INK, fontVariantNumeric: 'tabular-nums' }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 14 }}>
        <h1 style={{ margin: 0, fontSize: 22, fontWeight: 700 }}>Salle de contrôle</h1>
        <span style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 12px', borderRadius: 16, background: enDirect ? '#E8F4EE' : '#F1F2EE', color: enDirect ? '#116B4D' : DOUX, fontSize: 13, fontWeight: 600 }}>
          <span style={{ width: 8, height: 8, borderRadius: '50%', background: enDirect ? VERT : '#B9C0BB' }} />
          {enDirect ? 'En direct' : 'Hors ligne'}
        </span>
        <span style={{ fontSize: 13, color: GRIS }}>Mis à jour à {maj}</span>
        <span style={{ flex: 1 }} />
        <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 14 }}>
          <Switch checked={son} onChange={basculerSon} /> Son et notifications
        </label>
      </div>

      {erreur && <Alert type="error" showIcon message={erreur} />}

      {salle && (
        <>
          <Chiffres salle={salle} />
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 20, alignItems: 'stretch' }}>
            <Alertes salle={salle} ouvrir={(page) => naviguer(page)} voir={setFiche} />
            <Carte salle={salle} />
            <EnCours salle={salle} voir={setFiche} />
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 20 }}>
            <Boutiques salle={salle} />
            <Livreurs salle={salle} />
          </div>
        </>
      )}
      <FicheCommande orderId={fiche} onFerme={() => setFiche(null)} onChange={() => void charger()} />
    </div>
  );
}

function Chiffres({ salle }: { salle: Salle }) {
  const c = salle.chiffres;
  const motifs = c.motifs_annulation.slice(0, 2).map((m) => `${m.nombre} ${m.motif}`).join(', ');
  const tuiles: { titre: string; valeur: string; detail: string; couleur?: string }[] = [
    { titre: 'Commandes du jour', valeur: String(c.commandes), detail: 'depuis minuit' },
    { titre: 'En cours', valeur: String(c.en_cours), detail: c.en_cours_a_traiter ? `${c.en_cours_a_traiter} demandent une action` : 'tout va bien', couleur: c.en_cours_a_traiter ? ROUGE_TEXTE : '#116B4D' },
    { titre: 'Livrées', valeur: String(c.livrees), detail: c.duree_mediane_min === null ? '—' : `en ${c.duree_mediane_min} min (médiane)` },
    { titre: 'Annulées', valeur: String(c.annulees), detail: motifs || 'aucune' },
    { titre: 'Chiffre du jour', valeur: francs(c.chiffre_affaires), detail: `dont ${francs(c.livraison)} de livraison` },
    { titre: 'Livreurs en ligne', valeur: `${c.livreurs_en_ligne} / ${c.livreurs_total}`, detail: `${c.livreurs_libres} libres en ce moment` },
  ];
  return (
    <section style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 12 }}>
      {tuiles.map((t) => (
        <div key={t.titre} style={{ ...carteStyle, borderRadius: 16, padding: '16px 18px', display: 'flex', flexDirection: 'column', gap: 6 }}>
          <span style={{ fontSize: 13, color: DOUX }}>{t.titre}</span>
          <span style={{ fontSize: 28, fontWeight: 700, letterSpacing: -0.8 }}>{t.valeur}</span>
          <span style={{ fontSize: 12.5, color: t.couleur ?? DOUX }}>{t.detail}</span>
        </div>
      ))}
    </section>
  );
}

function Alertes({ salle, ouvrir, voir }: { salle: Salle; ouvrir: (page: string) => void; voir: (id: string) => void }) {
  const bouton: React.CSSProperties = { height: 36, padding: '0 14px', border: 0, borderRadius: 18, font: 'inherit', fontSize: 13.5, fontWeight: 600, cursor: 'pointer', display: 'inline-flex', alignItems: 'center', textDecoration: 'none' };
  return (
    <section style={{ ...carteStyle, flex: '1 1 340px', maxWidth: 420, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h2 style={titre2}>À traiter maintenant</h2>
        <span style={{ padding: '4px 10px', borderRadius: 12, background: salle.alertes.length ? '#FBE9E8' : '#E8F4EE', color: salle.alertes.length ? ROUGE_TEXTE : '#116B4D', fontSize: 13, fontWeight: 700 }}>{salle.alertes.length}</span>
      </div>
      {!salle.alertes.length && <span style={{ fontSize: 14, color: DOUX }}>Rien à traiter. Les alertes apparaissent ici dès qu’une commande dérape.</span>}
      {salle.alertes.map((a) => {
        const tel = telephone(a.action.tel);
        return (
          <article key={a.id} style={{ borderRadius: 14, background: FOND_GRAVITE[a.gravite], padding: 14, display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ width: 8, height: 8, borderRadius: '50%', background: POINT_GRAVITE[a.gravite], flexShrink: 0 }} />
              <span style={{ fontSize: 14.5, fontWeight: 700, flex: 1 }}>{a.titre}</span>
              <span style={{ fontSize: 13, fontWeight: 700, color: POINT_GRAVITE[a.gravite] }}>{dureeLisible(a.depuis_min)}</span>
            </div>
            <span style={{ fontSize: 13.5, color: '#3B4643', lineHeight: 1.4 }}>{a.detail}</span>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center' }}>
              {a.action.page && (
                <button type="button" style={{ ...bouton, background: INK, color: '#FFFFFF' }} onClick={() => ouvrir(a.action.page!)}>{a.action.libelle}</button>
              )}
              {a.action.tel !== undefined && (tel
                ? <a href={`tel:${tel}`} style={{ ...bouton, background: INK, color: '#FFFFFF' }}>{a.action.libelle} · {tel}</a>
                : <span style={{ fontSize: 13, color: DOUX }}>Pas de numéro enregistré</span>)}
              {a.commande_id && (
                <button type="button" style={{ ...bouton, background: '#FFFFFF', color: INK }} onClick={() => voir(a.commande_id!)}>Voir la commande</button>
              )}
            </div>
          </article>
        );
      })}
    </section>
  );
}

function Carte({ salle }: { salle: Salle }) {
  const boite = useRef<HTMLDivElement>(null);
  const carte = useRef<L.Map | null>(null);
  const calque = useRef<L.LayerGroup | null>(null);

  useEffect(() => {
    if (!boite.current || carte.current) return;
    carte.current = L.map(boite.current, { zoomControl: true, attributionControl: true }).setView([13.5137, 2.1098], 13);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 18,
      attribution: '© OpenStreetMap',
    }).addTo(carte.current);
    calque.current = L.layerGroup().addTo(carte.current);
    // Née avant que sa boîte ait sa taille finale, la carte ne chargeait
    // qu'une partie des tuiles et laissait le reste gris (capture du 02/11).
    const recaler = () => carte.current?.invalidateSize();
    const minuterie = window.setTimeout(recaler, 200);
    const observateur = new ResizeObserver(recaler);
    observateur.observe(boite.current);
    return () => {
      window.clearTimeout(minuterie);
      observateur.disconnect();
      carte.current?.remove();
      carte.current = null;
    };
  }, []);

  useEffect(() => {
    const groupe = calque.current;
    if (!groupe) return;
    groupe.clearLayers();
    const point = (couleur: string, rond: boolean, taille = 14, contour = '#FFFFFF') => L.divIcon({
      className: '',
      iconSize: [taille, taille],
      html: `<span style="display:block;width:${taille}px;height:${taille}px;border-radius:${rond ? '50%' : '4px'};background:${couleur};border:3px solid ${contour};box-sizing:border-box;box-shadow:0 1px 3px rgba(0,0,0,.25)"></span>`,
    });
    for (const b of salle.carte.boutiques) {
      L.marker([b.lat, b.lng], { icon: point(b.ouverte ? INK : '#9AA39F', false, 14) }).bindTooltip(b.nom).addTo(groupe);
    }
    for (const c of salle.carte.commandes) {
      const couleur = c.en_alerte ? ROUGE : BLEU;
      if (c.depart) L.polyline([[c.depart.lat, c.depart.lng], [c.lat, c.lng]], { color: couleur, weight: 3, dashArray: '6 6' }).addTo(groupe);
      L.marker([c.lat, c.lng], { icon: point('#FFFFFF', true, 16, couleur) }).bindTooltip(c.titre).addTo(groupe);
    }
    for (const l of salle.carte.livreurs) {
      L.marker([l.lat, l.lng], { icon: point(l.en_course ? BLEU : VERT, true, 18) }).bindTooltip(`${l.nom} · ${l.en_course ? 'en course' : 'libre'}`).addTo(groupe);
    }
  }, [salle]);

  const legende = (couleur: string, rond: boolean, texte: string, contour = false) => (
    <span style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, color: DOUX }}>
      <span style={{ width: 10, height: 10, borderRadius: rond ? '50%' : 3, background: contour ? '#FFFFFF' : couleur, border: contour ? `2px solid ${couleur}` : undefined, boxSizing: 'border-box' }} />{texte}
    </span>
  );
  return (
    <section style={{ ...carteStyle, flex: '999 1 460px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 14 }}>
        <h2 style={{ ...titre2, flex: 1 }}>Niamey, en ce moment</h2>
        {legende(INK, false, 'Boutique')}
        {legende(INK, true, 'Client', true)}
        {legende(VERT, true, 'Livreur libre')}
        {legende(BLEU, true, 'Livreur en course')}
      </div>
      <div ref={boite} style={{ flex: 1, minHeight: 520, borderRadius: 14, overflow: 'hidden' }} />
    </section>
  );
}

function EnCours({ salle, voir }: { salle: Salle; voir: (id: string) => void }) {
  return (
    <section style={{ ...carteStyle, flex: '1 1 320px', maxWidth: 400, display: 'flex', flexDirection: 'column', gap: 4 }}>
      <h2 style={{ ...titre2, marginBottom: 8 }}>Commandes en cours</h2>
      {!salle.en_cours.length && <span style={{ fontSize: 14, color: DOUX }}>Aucune commande en cours.</span>}
      {salle.en_cours.map((o) => (
        <button type="button" key={o.id} onClick={() => voir(o.id)} style={{ padding: '12px 0', border: 0, borderBottom: '1px solid #EEF0EC', background: 'transparent', font: 'inherit', color: 'inherit', textAlign: 'left', cursor: 'pointer', display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{ fontSize: 14.5, fontWeight: 700, flex: 1 }}>{o.boutique}</span>
            <span style={{ fontSize: 13, fontWeight: 600, color: o.en_alerte ? ROUGE_TEXTE : DOUX }}>{dureeLisible(o.age_min)}</span>
          </span>
          <span style={{ fontSize: 13, color: DOUX }}>{o.client} · {o.lieu} · {francs(o.total)}</span>
          <span style={{ display: 'grid', gridTemplateColumns: 'repeat(5, minmax(0, 1fr))', gap: 4 }}>
            {[0, 1, 2, 3, 4].map((i) => (
              <span key={i} style={{ height: 5, borderRadius: 3, background: i < o.etape ? INK : i === o.etape ? (o.en_alerte ? ROUGE : BLEU) : '#E3E6E0' }} />
            ))}
          </span>
          <span style={{ fontSize: 12.5, color: '#3B4643' }}>{o.statut}{o.livreur ? ` · ${o.livreur.split(/\s+/)[0]}` : ''}</span>
        </button>
      ))}
    </section>
  );
}

function Boutiques({ salle }: { salle: Salle }) {
  const th: React.CSSProperties = { padding: '8px 6px', fontWeight: 600 };
  const td: React.CSSProperties = { padding: '11px 6px' };
  return (
    <section style={{ ...carteStyle, flex: '999 1 560px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 10 }}>
      <h2 style={titre2}>Boutiques aujourd’hui</h2>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14, minWidth: 600 }}>
          <thead>
            <tr style={{ textAlign: 'left', color: GRIS, fontSize: 12.5 }}>
              <th style={th}>Boutique</th><th style={th}>État</th>
              <th style={{ ...th, textAlign: 'right' }}>Commandes</th>
              <th style={{ ...th, textAlign: 'right' }}>Acceptée en</th>
              <th style={{ ...th, textAlign: 'right' }}>Annulées</th>
              <th style={th}>À noter</th>
            </tr>
          </thead>
          <tbody>
            {salle.boutiques.map((b) => (
              <tr key={b.id} style={{ borderTop: '1px solid #EEF0EC' }}>
                <td style={{ ...td, fontWeight: 600 }}>{b.nom}</td>
                <td style={td}>
                  <span style={{ padding: '4px 10px', borderRadius: 12, fontSize: 12.5, fontWeight: 600, background: b.ouverte ? '#E8F4EE' : '#F1F2EE', color: b.ouverte ? '#116B4D' : DOUX }}>{b.ouverte ? 'Ouverte' : 'Fermée'}</span>
                </td>
                <td style={{ ...td, textAlign: 'right' }}>{b.commandes}</td>
                <td style={{ ...td, textAlign: 'right', fontWeight: 600, color: b.delai_acceptation_min === null ? DOUX : b.delai_acceptation_min > 5 ? ROUGE_TEXTE : '#116B4D' }}>
                  {b.delai_acceptation_min === null ? '—' : `${b.delai_acceptation_min} min`}
                </td>
                <td style={{ ...td, textAlign: 'right' }}>{b.annulees}</td>
                <td style={{ ...td, color: b.note ? ROUGE_TEXTE : DOUX }}>{b.note ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function Livreurs({ salle }: { salle: Salle }) {
  const couleur: Record<string, string> = { en_course: BLEU, libre: VERT, hors_ligne: '#B9C0BB' };
  const c = salle.chiffres;
  return (
    <section style={{ ...carteStyle, flex: '1 1 320px', maxWidth: 460, display: 'flex', flexDirection: 'column', gap: 4 }}>
      <h2 style={{ ...titre2, marginBottom: 8 }}>Livreurs <span style={{ fontWeight: 500, color: GRIS }}>· {c.livreurs_en_ligne} en ligne sur {c.livreurs_total}</span></h2>
      {salle.livreurs.map((l) => (
        <div key={l.id} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '9px 0', borderBottom: '1px solid #EEF0EC' }}>
          <span style={{ width: 10, height: 10, borderRadius: '50%', background: couleur[l.etat], flexShrink: 0 }} />
          <span style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 14.5, fontWeight: 600 }}>{l.nom}</span>
            <span style={{ fontSize: 12.5, color: DOUX }}>{l.detail}</span>
          </span>
          <span style={{ fontSize: 13, color: DOUX }}>{l.courses_du_jour} course{l.courses_du_jour > 1 ? 's' : ''}</span>
        </div>
      ))}
    </section>
  );
}
