import DiffReviewer.Types

namespace DiffReviewer

private def htmlEscape (s : String) : String :=
  s.foldl (fun acc c =>
    acc ++ match c with
      | '&'  => "&amp;"
      | '<'  => "&lt;"
      | '>'  => "&gt;"
      | '"'  => "&quot;"
      | '\'' => "&#39;"
      | c    => String.singleton c) ""

private def decisionLabel : Decision → String
  | .comment        => "Comment"
  | .approve        => "Approved"
  | .requestChanges => "Changes Requested"

private def decisionClass : Decision → String
  | .comment        => "decision-comment"
  | .approve        => "decision-approve"
  | .requestChanges => "decision-changes"

private def renderSuggestion (s : String) : String :=
  s!"<pre class=\"suggestion\"><code>{htmlEscape s}</code></pre>"

private def renderComment (c : InlineComment) : String :=
  let suggestion := match c.suggestion with
    | none   => ""
    | some s => renderSuggestion s
  let body := if c.body.isEmpty then ""
    else s!"<div class=\"comment-body\">{htmlEscape c.body}</div>\n"
  s!"{body}<div class=\"inline-comment\">
  <div class=\"comment-location\">{htmlEscape c.file} \
line {c.range.startLine}–{c.range.endLine}</div>
  {suggestion}
</div>"

private def renderComments (cs : List InlineComment) : String :=
  if cs.isEmpty then "<p><em>No inline comments.</em></p>"
  else cs.map renderComment |>.foldl (fun acc s => acc ++ s ++ "\n") ""

private def css : String := "
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
       max-width: 960px; margin: 40px auto; padding: 0 20px;
       background: #f6f8fa; color: #24292e; }
h1 { font-size: 1.4rem; border-bottom: 1px solid #e1e4e8; padding-bottom: 8px; }
h2 { font-size: 1.1rem; margin-top: 32px; }
.decision { display: inline-block; padding: 4px 12px; border-radius: 20px;
            font-weight: 600; font-size: 0.9rem; margin-bottom: 16px; }
.decision-approve  { background: #dcffe4; color: #176f2c; }
.decision-changes  { background: #ffeef0; color: #86181d; }
.decision-comment  { background: #fff3cd; color: #856404; }
.review-body { background: #fff; border: 1px solid #e1e4e8; border-radius: 6px;
               padding: 16px; white-space: pre-wrap; margin-bottom: 24px; }
.inline-comment { background: #fff; border: 1px solid #e1e4e8; border-radius: 6px;
                  margin-bottom: 16px; overflow: hidden; }
.comment-location { background: #f1f8ff; border-bottom: 1px solid #c8e1ff;
                    padding: 8px 16px; font-size: 0.85rem;
                    font-family: monospace; color: #0366d6; }
.comment-body { padding: 4px 0 8px 0; white-space: pre-wrap; font-weight: 600; }
.suggestion { margin: 0; background: #f6f8fa; border-top: 1px solid #e1e4e8;
              padding: 12px 16px; overflow-x: auto; }
.suggestion code { font-family: 'SFMono-Regular', Consolas, monospace;
                   font-size: 0.85rem; }
"

def Review.toHtml (r : Review) : String :=
  let decClass := decisionClass r.decision
  let decLbl   := decisionLabel r.decision
  s!"<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>Diff Review</title>
<style>{css}</style>
</head>
<body>
<h1>Diff Review</h1>
<div class=\"decision {decClass}\">{decLbl}</div>
<h2>Summary</h2>
<div class=\"review-body\">{htmlEscape r.body}</div>
<h2>Inline Comments ({r.comments.length})</h2>
{renderComments r.comments}
</body>
</html>"

end DiffReviewer
