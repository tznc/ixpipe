# Runic hashes every fact it produces. Hashing a frame's contents would cost
# a full serialisation per node, so a frame's identity is its native resource:
# unique per frame within this VM, which is all a run needs.
defimpl Runic.Identity.Projectable, for: Explorer.DataFrame do
  def identity_document(df), do: %{resource: :erlang.term_to_binary(df.data)}
end
