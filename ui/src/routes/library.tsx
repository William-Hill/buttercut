import "./library.css";

export default function Library({ name }: { name: string }) {
  return (
    <main className="library">
      <header className="library__header">
        <p className="library__eyebrow">Library</p>
        <h1 className="library__title">{name}</h1>
      </header>
      <section className="library__placeholder">
        <p className="library__placeholder-line">
          Footage browser, transcripts, and cuts arrive in the next milestones.
        </p>
        <p className="library__placeholder-meta">M1 · footage browser</p>
      </section>
    </main>
  );
}
