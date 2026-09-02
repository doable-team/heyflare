import { Link } from "react-router-dom";
import { Search } from "lucide-react";
import { EmptyState } from "../components/EmptyState";
import { Button } from "@/components/ui/button";

export default function NotFound() {
  return (
    <div className="max-w-3xl mx-auto pt-10">
      <EmptyState
        icon={<Search />}
        title="That page wandered off."
        body="Nothing lives at this address."
        action={
          <Button variant="ghost" size="sm" asChild>
            <Link to="/">Back to the Imbox</Link>
          </Button>
        }
      />
    </div>
  );
}
