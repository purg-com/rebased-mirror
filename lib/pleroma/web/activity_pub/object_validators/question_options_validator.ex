# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.QuestionOptionsValidator do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.EctoType.ActivityPub.ObjectValidators

  @primary_key false

  embedded_schema do
    field(:name, :string)
    field(:nameMap, ObjectValidators.MapOfString)

    embeds_one :replies, Replies, primary_key: false do
      field(:totalItems, :integer)
      field(:type, :string)
    end

    field(:type, :string)
  end

  def changeset(struct, data) do
    struct
    |> cast(data, [:name, :nameMap, :type])
    |> cast_embed(:replies, with: &replies_changeset/2)
    |> validate_inclusion(:type, ["Note"])
    |> validate_required([:name, :type])
  end

  def replies_changeset(struct, data) do
    struct
    |> cast(data, [:totalItems, :type])
    |> validate_inclusion(:type, ["Collection"])
    |> validate_required([:type])
  end
end
