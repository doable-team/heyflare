import { useEffect } from "react";
import { Navigate, Route, Routes, useLocation } from "react-router-dom";
import { Shell } from "./components/Shell";
import Imbox from "./pages/Imbox";
import { page, warm } from "./lib/lazy";

// Every page is its own chunk. The Imbox is where a session lands, so it ships with the shell
// rather than costing a second round trip on every visit.
const Feed = page(() => import("./pages/Feed"));
const PowerThrough = page(() => import("./pages/PowerThrough"));
const PaperTrail = page(() => import("./pages/PaperTrail"));
const Screener = page(() => import("./pages/Screener"));
const ReplyLater = page(() => import("./pages/ReplyLater"));
const SetAside = page(() => import("./pages/SetAside"));
const BubbleUp = page(() => import("./pages/BubbleUp"));
const ListPage = page(() => import("./pages/ListPage"));
const ScreenedOut = page(() => import("./pages/ScreenedOut"));
const Thread = page(() => import("./pages/Thread"));
const ComposePage = page(() => import("./pages/Compose"));
const Drafts = page(() => import("./pages/Drafts"));
const Contacts = page(() => import("./pages/Contacts"));
const ContactDetail = page(() => import("./pages/ContactDetail"));
const ContactByEmail = page(() => import("./pages/ContactByEmail"));
const BundlePage = page(() => import("./pages/BundlePage"));
const Clips = page(() => import("./pages/Clips"));
const Collections = page(() => import("./pages/Collections"));
const CollectionDetail = page(() => import("./pages/CollectionDetail"));
const FilesPage = page(() => import("./pages/Files"));
const Labels = page(() => import("./pages/Labels"));
const LabelThreads = page(() => import("./pages/LabelThreads"));
const SettingsPage = page(() => import("./pages/Settings"));
const Assistant = page(() => import("./pages/Assistant"));
const CalendarPage = page(() => import("./pages/Calendar"));
const Journal = page(() => import("./pages/Journal"));
const Habits = page(() => import("./pages/Habits"));
const SearchPage = page(() => import("./pages/Search"));
const NotFound = page(() => import("./pages/NotFound"));

/** The pages nearly every session reaches. Fetched once the first paint is out of the way. */
const COMMON = [Thread, Feed, PaperTrail, Screener, ReplyLater, SetAside, SearchPage, SettingsPage, CalendarPage];

/** Desktop keeps hash tabs; mobile deep links like /settings/accounts map onto them. */
function SettingsRedirect() {
  const loc = useLocation();
  const seg = loc.pathname.split("/")[2] ?? "profile";
  const tab = ["profile", "preferences", "accounts", "domains", "security"].includes(seg) ? seg : "profile";
  return <Navigate to={`/settings#${tab}`} replace />;
}

export default function DesktopApp() {
  useEffect(() => warm(COMMON), []);
  return (
    <Routes>
      <Route element={<Shell />}>
        <Route path="/" element={<Imbox />} />
        <Route path="/feed" element={<Feed />} />
        <Route path="/power-through" element={<PowerThrough />} />
        <Route path="/paper-trail" element={<PaperTrail />} />
        <Route path="/screener" element={<Screener />} />
        <Route path="/screened-out" element={<ScreenedOut />} />
        <Route path="/reply-later" element={<ReplyLater />} />
        <Route path="/set-aside" element={<SetAside />} />
        <Route path="/bubble-up" element={<BubbleUp />} />
        <Route path="/previously-seen" element={<ListPage key="seen" bucket="previously_seen" title="Previously seen" subtitle="Everything you've already looked at." />} />
        <Route path="/trash" element={<ListPage key="trash" bucket="trash" title="Trash" subtitle="Gone, but not forgotten. Yet." />} />
        <Route path="/sent" element={<ListPage key="sent" bucket="sent" title="Sent" subtitle="Things you've said." />} />
        <Route path="/everything" element={<ListPage key="everything" bucket="everything" title="Everything" subtitle="All your mail, every bucket, one list." showBucket />} />
        <Route path="/labels" element={<Labels />} />
        <Route path="/labels/:id" element={<LabelThreads />} />
        <Route path="/t/:id" element={<Thread />} />
        <Route path="/compose" element={<ComposePage />} />
        <Route path="/drafts" element={<Drafts mode="draft" />} />
        <Route path="/scheduled" element={<Drafts mode="scheduled" />} />
        <Route path="/contacts" element={<Contacts />} />
        <Route path="/contacts/email/:email" element={<ContactByEmail />} />
        <Route path="/contacts/:id" element={<ContactDetail />} />
        <Route path="/bundle/:id" element={<BundlePage />} />
        <Route path="/clips" element={<Clips />} />
        <Route path="/collections" element={<Collections />} />
        <Route path="/collections/:id" element={<CollectionDetail />} />
        <Route path="/files" element={<FilesPage />} />
        <Route path="/calendar" element={<CalendarPage />} />
        <Route path="/journal" element={<Journal />} />
        <Route path="/journal/:date" element={<Journal />} />
        <Route path="/habits" element={<Habits />} />
        <Route path="/assistant" element={<Assistant />} />
        <Route path="/assistant/:id" element={<Assistant />} />
        <Route path="/settings" element={<SettingsPage />} />
        <Route path="/settings/*" element={<SettingsRedirect />} />
        <Route path="/search" element={<SearchPage />} />
        <Route path="/more" element={<Imbox />} />
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  );
}
