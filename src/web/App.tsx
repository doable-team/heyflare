import { Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AccountProvider } from "./context/AccountContext";
import { ComposeProvider } from "./context/ComposeContext";
import { Toaster } from "@/components/ui/toaster-shim";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useIsMobile } from "@/hooks/use-mobile";
import { Shell } from "./components/Shell";
import Login from "./pages/Login";
import Setup from "./pages/Setup";
import Imbox from "./pages/Imbox";
import Feed from "./pages/Feed";
import PowerThrough from "./pages/PowerThrough";
import PaperTrail from "./pages/PaperTrail";
import Screener from "./pages/Screener";
import ReplyLater from "./pages/ReplyLater";
import SetAside from "./pages/SetAside";
import BubbleUp from "./pages/BubbleUp";
import ListPage from "./pages/ListPage";
import ScreenedOut from "./pages/ScreenedOut";
import Thread from "./pages/Thread";
import ComposePage from "./pages/Compose";
import Drafts from "./pages/Drafts";
import Contacts from "./pages/Contacts";
import ContactDetail from "./pages/ContactDetail";
import ContactByEmail from "./pages/ContactByEmail";
import BundlePage from "./pages/BundlePage";
import MobileBundle from "./mobile/MobileBundle";
import Clips from "./pages/Clips";
import Collections from "./pages/Collections";
import CollectionDetail from "./pages/CollectionDetail";
import FilesPage from "./pages/Files";
import Labels from "./pages/Labels";
import LabelThreads from "./pages/LabelThreads";
import SettingsPage from "./pages/Settings";
import Assistant from "./pages/Assistant";
import { MobileAssistantList, MobileAssistantChat } from "./mobile/MobileAssistant";
import SearchPage from "./pages/Search";
import NotFound from "./pages/NotFound";
import { MobileShell } from "./mobile/MobileShell";
import MobileImbox from "./mobile/MobileImbox";
import MobileFeed from "./mobile/MobileFeed";
import MobilePowerThrough from "./mobile/MobilePowerThrough";
import MobileScreener from "./mobile/MobileScreener";
import MobileThread from "./mobile/MobileThread";
import MobileMore from "./mobile/MobileMore";
import { MobileBucketScreen, MobileLabelThreads, MobileSearch, BUCKETS } from "./mobile/MobileListScreen";
import { MobilePageWrap } from "./mobile/MobilePageWrap";
import MobileSettings, { MobileSettingsAccountDetail, MobileSettingsAccounts, MobileSettingsDomainDetail, MobileSettingsDomains, MobileSettingsPreferences, MobileSettingsProfile, MobileSettingsSecurity, MobileSettingsAi } from "./mobile/MobileSettings";

/** Desktop keeps hash tabs; mobile deep links like /settings/accounts map onto them. */
function SettingsRedirect() {
  const loc = useLocation();
  const seg = loc.pathname.split("/")[2] ?? "profile";
  const tab = ["profile", "preferences", "accounts", "domains", "security"].includes(seg) ? seg : "profile";
  return <Navigate to={`/settings#${tab}`} replace />;
}

function DesktopRoutes() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route path="/setup" element={<Setup />} />
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

function MobileRoutes() {
  const wrap = (title: string, el: React.ReactNode, tabs = true) => <MobilePageWrap title={title} tabs={tabs}>{el}</MobilePageWrap>;
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route path="/setup" element={<Setup />} />
      <Route element={<MobileShell />}>
        <Route path="/" element={<MobileImbox />} />
        <Route path="/feed" element={<MobileFeed />} />
        <Route path="/power-through" element={<MobilePowerThrough />} />
        <Route path="/paper-trail" element={<MobileBucketScreen bucket="paper_trail" cfg={BUCKETS.paper_trail} />} />
        <Route path="/screener" element={<MobileScreener />} />
        <Route path="/more" element={<MobileMore />} />
        <Route path="/screened-out" element={wrap("", <ScreenedOut />)} />
        <Route path="/reply-later" element={<MobileBucketScreen key="rl" bucket="reply_later" back cfg={BUCKETS.reply_later} />} />
        <Route path="/set-aside" element={<MobileBucketScreen key="sa" bucket="set_aside" back cfg={BUCKETS.set_aside} />} />
        <Route path="/bubble-up" element={<MobileBucketScreen key="bu" bucket="bubble_up" back cfg={BUCKETS.bubble_up} />} />
        <Route path="/previously-seen" element={<MobileBucketScreen key="ps" bucket="previously_seen" back cfg={BUCKETS.previously_seen} />} />
        <Route path="/trash" element={<MobileBucketScreen key="tr" bucket="trash" back cfg={BUCKETS.trash} />} />
        <Route path="/sent" element={<MobileBucketScreen key="se" bucket="sent" back cfg={BUCKETS.sent} />} />
        <Route path="/everything" element={<MobileBucketScreen key="ev" bucket="everything" back cfg={BUCKETS.everything} />} />
        <Route path="/labels" element={wrap("", <Labels />)} />
        <Route path="/labels/:id" element={<MobileLabelThreads />} />
        <Route path="/t/:id" element={<MobileThread />} />
        <Route path="/compose" element={wrap("", <ComposePage />, false)} />
        <Route path="/drafts" element={wrap("", <Drafts mode="draft" />)} />
        <Route path="/scheduled" element={wrap("", <Drafts mode="scheduled" />)} />
        <Route path="/contacts" element={wrap("", <Contacts />)} />
        <Route path="/contacts/:id" element={wrap("", <ContactDetail />)} />
        <Route path="/bundle/:id" element={<MobileBundle />} />
        <Route path="/clips" element={wrap("", <Clips />)} />
        <Route path="/collections" element={wrap("", <Collections />)} />
        <Route path="/collections/:id" element={wrap("", <CollectionDetail />)} />
        <Route path="/files" element={wrap("", <FilesPage />)} />
        <Route path="/settings" element={<MobileSettings />} />
        <Route path="/settings/profile" element={<MobileSettingsProfile />} />
        <Route path="/settings/preferences" element={<MobileSettingsPreferences />} />
        <Route path="/settings/accounts" element={<MobileSettingsAccounts />} />
        <Route path="/settings/accounts/:id" element={<MobileSettingsAccountDetail />} />
        <Route path="/settings/domains" element={<MobileSettingsDomains />} />
        <Route path="/settings/domains/:id" element={<MobileSettingsDomainDetail />} />
        <Route path="/settings/security" element={<MobileSettingsSecurity />} />
        <Route path="/settings/ai" element={<MobileSettingsAi />} />
        <Route path="/assistant" element={<MobileAssistantList />} />
        <Route path="/assistant/:id" element={<MobileAssistantChat />} />
        <Route path="/search" element={<MobileSearch />} />
        <Route path="*" element={wrap("", <NotFound />)} />
      </Route>
    </Routes>
  );
}

export default function App() {
  const mobile = useIsMobile();
  return (
    <TooltipProvider delayDuration={300}>
      <Toaster />
      <AccountProvider>
        <ComposeProvider>{mobile ? <MobileRoutes /> : <DesktopRoutes />}</ComposeProvider>
      </AccountProvider>
    </TooltipProvider>
  );
}
