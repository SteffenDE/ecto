defmodule Ecto.Query.Normalizer do
  @moduledoc false

  # Normalizes a query so that it is as consistent as possible.

  alias Ecto.Query.QueryExpr
  alias Ecto.Query.JoinExpr
  alias Ecto.Query.Util

  def normalize(query, opts \\ []) do
    query
    |> setup_sources
    |> normalize_joins
    |> auto_select(opts)
    |> normalize_distinct
    |> normalize_group_by
  end

  defp normalize_joins(query) do
    %{query | joins: Enum.map(query.joins, &normalize_join(&1, query))}
  end

  # Transform an assocation join to an ordinary join
  def normalize_join(%JoinExpr{assoc: nil} = join, _query), do: join

  def normalize_join(%JoinExpr{assoc: {left, right}} = join, query) do
    model = Util.find_source(query.sources, left) |> Util.model

    if nil?(model) do
      raise Ecto.QueryError, file: join.file, line: join.line,
        reason: "association join cannot be performed without a model"
    end

    refl = model.__schema__(:association, right)

    unless refl do
      raise Ecto.QueryError, file: join.file, line: join.line,
        reason: "could not find association `#{right}` on model #{inspect model}"
    end

    associated = refl.associated
    assoc_var = Util.model_var(query, associated)
    on_expr = on_expr(join.on, refl, assoc_var, left)
    on = %QueryExpr{expr: on_expr, file: join.file, line: join.line}
    %{join | source: associated, on: on}
  end

  defp on_expr(on_expr, refl, assoc_var, struct_var) do
    key = refl.key
    assoc_key = refl.assoc_key
    relation = quote do
      unquote(assoc_var).unquote(assoc_key) == unquote(struct_var).unquote(key)
    end

    if on_expr do
      quote do: unquote(on_expr.expr) and unquote(relation)
    else
      relation
    end
  end

  # Auto select the model in the from expression
  defp auto_select(query, opts) do
    if !opts[:skip_select] && query.select == nil do
      var = {:&, [], [0]}
      %{query | select: %QueryExpr{expr: var}}
    else
      query
    end
  end

  # Group by all fields
  defp normalize_group_by(query) do
    exprs = normalize_exprs(query.group_bys, query.sources)
    %{query | group_bys: exprs}
  end

  # Add distinct on all field when model is in field list
  defp normalize_distinct(query) do
    exprs = normalize_exprs(query.distincts, query.sources)
    %{query | distincts: exprs}
  end

  # Expand var into all of its fields in an expression
  defp normalize_exprs(query_expr, sources) do
    Enum.map(query_expr, fn expr ->
      new_expr =
        Enum.flat_map(expr.expr, fn
          {:&, _, _} = var ->
            model = Util.find_source(sources, var) |> Util.model
            fields = model.__schema__(:field_names)
            Enum.map(fields, &{{:., [], [var, &1]}, [], []})
          expr ->
            [expr]
        end)
      %{expr | expr: new_expr}
    end)
  end

  # Adds all sources to the query for fast access
  defp setup_sources(query) do
    froms = if query.from, do: [query.from], else: []

    sources = Enum.reduce(query.joins, froms, fn
      %JoinExpr{assoc: {left, right}}, acc ->
        model = Util.find_source(Enum.reverse(acc), left) |> Util.model

        if model && (refl = model.__schema__(:association, right)) do
          assoc = refl.associated
          [ {assoc.__schema__(:source), assoc} | acc ]
        else
          [nil|acc]
        end

      # TODO: Validate this on join creation
      %JoinExpr{source: source}, acc when is_binary(source) ->
        [ {source, nil} | acc ]

      %JoinExpr{source: model}, acc when is_atom(model) ->
        [ {model.__schema__(:source), model} | acc ]
    end)

    %{query | sources: sources |> Enum.reverse |> list_to_tuple}
  end
end
