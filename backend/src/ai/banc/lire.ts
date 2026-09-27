/**
 * Lire TOUTES les lignes d'une requête Supabase, page par page.
 *
 * Supabase (PostgREST) plafonne une réponse à 1 000 lignes, quel que soit le
 * `.limit()` demandé : l'examen du banc lisait 1 000 phrases alors que la
 * banque en comptait 2 404 (27/09). `construire(de, a)` doit renvoyer la
 * requête avec `.range(de, a)` appliqué, dans un ordre stable.
 */
export async function toutLire<T>(
  construire: (de: number, a: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
  maximum = 100_000,
  page = 1000,
): Promise<{ data: T[]; error: { message: string } | null }> {
  const tout: T[] = [];
  for (let de = 0; de < maximum; de += page) {
    const { data, error } = await construire(de, de + page - 1);
    if (error) return { data: tout, error };
    tout.push(...(data ?? []));
    if ((data ?? []).length < page) break;
  }
  return { data: tout, error: null };
}
